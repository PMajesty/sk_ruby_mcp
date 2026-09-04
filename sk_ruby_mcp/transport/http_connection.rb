# frozen_string_literal: true

require 'json'
require 'socket'

module SkRubyMcp
  module Transport
    HttpRequest = Struct.new(:method, :path, :headers, :body, keyword_init: true)

    # Ответ сервера: тело отдаётся целиком с Content-Length, соединение всегда закрывается.
    class HttpResponse
      STATUS_TEXT = {
        200 => 'OK', 202 => 'Accepted',
        400 => 'Bad Request', 401 => 'Unauthorized', 403 => 'Forbidden', 404 => 'Not Found',
        405 => 'Method Not Allowed', 408 => 'Request Timeout', 411 => 'Length Required',
        413 => 'Payload Too Large', 431 => 'Request Header Fields Too Large',
        500 => 'Internal Server Error', 503 => 'Service Unavailable'
      }.freeze
      JSON_CONTENT_TYPE = 'application/json; charset=utf-8'

      attr_reader :status, :headers, :body

      def initialize(status, body: '', headers: {})
        @status = status
        @body = body
        @headers = headers
      end

      def self.json(status, payload, headers: {})
        new(status, body: JSON.generate(payload), headers: { 'Content-Type' => JSON_CONTENT_TYPE }.merge(headers))
      end

      def self.empty(status, headers: {})
        new(status, headers: headers)
      end

      # Сериализация в байты; заголовки ASCII, тело может содержать любые байты.
      def to_s
        body_bytes = @body.to_s.b
        lines = ["HTTP/1.1 #{@status} #{STATUS_TEXT.fetch(@status, 'Unknown')}"]
        @headers.each { |name, value| lines << "#{name}: #{value}" }
        lines << "Content-Length: #{body_bytes.bytesize}"
        lines << 'Connection: close'
        "#{lines.join("\r\n")}\r\n\r\n".b + body_bytes
      end
    end

    # Одно клиентское соединение: неблокирующее чтение с дедлайном, разбор HTTP/1.1, отправка ответа.
    # Состояния: :reading_head, :reading_body, :complete, :rejected, :closed.
    class HttpConnection
      Limits = Struct.new(:max_header_bytes, :max_body_bytes, :read_deadline_s, :write_deadline_s, keyword_init: true)
      DEFAULT_LIMITS = Limits.new(
        max_header_bytes: 16 * 1024,
        max_body_bytes: 1024 * 1024,
        read_deadline_s: 5.0,
        write_deadline_s: 0.5
      ).freeze
      READ_CHUNK_BYTES = 64 * 1024
      HEADER_TERMINATOR = /\r?\n\r?\n/.freeze
      REQUEST_LINE = %r{\A([A-Z]+) (\S+) HTTP/1\.[01]\z}.freeze
      CONTENT_LENGTH = /\A\d{1,12}\z/.freeze
      METHODS_WITH_BODY = %w[POST PUT PATCH].freeze
      CONTINUE_RESPONSE = "HTTP/1.1 100 Continue\r\n\r\n"

      attr_reader :request, :rejection

      def initialize(socket, limits: DEFAULT_LIMITS, now: Clock.now)
        @socket = socket
        @limits = limits
        @deadline = now + limits.read_deadline_s
        @buffer = String.new(encoding: Encoding::BINARY)
        @state = :reading_head
        @request = nil
        @rejection = nil
        @expected_body_bytes = 0
      end

      # Продвигает чтение и возвращает текущее состояние.
      def pump(now)
        return @state unless reading?

        if now >= @deadline
          reject(408, 'Request timeout')
        else
          read_available
        end
        @state
      end

      def send_response(response)
        data = response.to_s
        deadline = Clock.now + @limits.write_deadline_s
        until data.empty?
          written = @socket.write_nonblock(data, exception: false)
          if written == :wait_writable
            remaining = deadline - Clock.now
            return false if remaining <= 0

            IO.select(nil, [@socket], nil, remaining)
          else
            data = data.byteslice(written, data.bytesize - written)
          end
        end
        true
      rescue SystemCallError, IOError
        false
      end

      def close
        @socket.close unless @socket.closed?
      rescue IOError
        nil
      end

      private

      def reading?
        @state == :reading_head || @state == :reading_body
      end

      def read_available
        while reading?
          chunk = @socket.read_nonblock(READ_CHUNK_BYTES, exception: false)
          break if chunk == :wait_readable

          if chunk.nil?
            @state = :closed
            break
          end
          @buffer << chunk
          advance
        end
      rescue SystemCallError, IOError
        @state = :closed
      end

      def advance
        parse_head if @state == :reading_head
        finish_body if @state == :reading_body
      end

      def parse_head
        match = HEADER_TERMINATOR.match(@buffer)
        if match.nil?
          reject(431, 'Request header too large') if @buffer.bytesize > @limits.max_header_bytes
          return
        end

        head = @buffer.byteslice(0, match.begin(0))
        @buffer = @buffer.byteslice(match.end(0), @buffer.bytesize - match.end(0))
        parsed = parse_head_text(TextTrimmer.utf8(head))
        return unless parsed

        method, path, headers = parsed
        @request = HttpRequest.new(method: method, path: path, headers: headers, body: '')
        prepare_body(method, headers)
      end

      # [метод, путь без query, заголовки в нижнем регистре] или nil после reject.
      def parse_head_text(head)
        lines = head.split(/\r?\n/)
        match = REQUEST_LINE.match(lines.shift.to_s)
        return reject(400, 'Malformed request line') unless match

        headers = {}
        lines.each do |line|
          name, value = line.split(':', 2)
          return reject(400, 'Malformed header line') if value.nil? || name.strip.empty?

          key = name.strip.downcase
          headers[key] = headers.key?(key) ? "#{headers[key]}, #{value.strip}" : value.strip
        end
        [match[1], match[2].split('?', 2).first, headers]
      end

      def prepare_body(method, headers)
        length_header = headers['content-length']
        if headers.key?('transfer-encoding') || (length_header.nil? && METHODS_WITH_BODY.include?(method))
          return reject(411, 'Content-Length is required')
        end
        return complete if length_header.nil?
        return reject(400, 'Malformed Content-Length') unless CONTENT_LENGTH.match?(length_header)

        @expected_body_bytes = length_header.to_i
        return reject(413, "Body exceeds #{@limits.max_body_bytes} bytes") if @expected_body_bytes > @limits.max_body_bytes

        acknowledge_expect_continue(headers)
        @state = :reading_body
        finish_body
      end

      # curl и некоторые клиенты ждут 100 Continue до секунды, прежде чем прислать тело.
      def acknowledge_expect_continue(headers)
        return unless headers['expect'].to_s.casecmp('100-continue').zero?

        @socket.write_nonblock(CONTINUE_RESPONSE, exception: false)
      rescue SystemCallError, IOError
        nil
      end

      def finish_body
        return if @buffer.bytesize < @expected_body_bytes

        @request.body = @buffer.byteslice(0, @expected_body_bytes)
        complete
      end

      def complete
        @state = :complete
      end

      def reject(status, message)
        @state = :rejected
        @rejection = HttpResponse.json(status, { error: message })
        nil
      end
    end
  end
end
