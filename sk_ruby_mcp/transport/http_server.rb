# frozen_string_literal: true

require 'socket'

module SkRubyMcp
  module Transport
    # Планировщик на таймере SketchUp: единственный способ регулярно получать управление на главном потоке.
    class UiTimerScheduler
      def every(interval_s, &block)
        cancel
        @timer_id = UI.start_timer(interval_s, true, &block)
      end

      def cancel
        UI.stop_timer(@timer_id) if @timer_id
        @timer_id = nil
      end
    end

    # HTTP-сервер на loopback: слушающий сокет, пампа соединений по таймеру, статистика.
    # Всё выполняется на главном потоке SketchUp, блокирующих вызовов нет.
    class HttpServer
      Limits = Struct.new(:max_connections, :accepts_per_tick, :settlements_per_tick, keyword_init: true)
      DEFAULT_LIMITS = Limits.new(max_connections: 16, accepts_per_tick: 8, settlements_per_tick: 4).freeze

      attr_reader :host, :port, :stats

      def initialize(host:, port:, pump_interval:, request_handler:, scheduler:, log:,
                     limits: DEFAULT_LIMITS, connection_limits: HttpConnection::DEFAULT_LIMITS,
                     socket_options: Platform)
        @host = host
        @port = port
        @pump_interval = pump_interval
        @request_handler = request_handler
        @scheduler = scheduler
        @log = log
        @limits = limits
        @connection_limits = connection_limits
        @socket_options = socket_options
        @connections = []
        @listener = nil
        @running = false
        @started_at = nil
        reset_stats
      end

      def running?
        @running
      end

      def start
        return true if @running

        @listener = TCPServer.new(@host, @port)
        @started_at = Clock.now
        reset_stats
        @scheduler.every(@pump_interval) { tick }
        @running = true
        @log.info("listening on http://#{@host}:#{@port}/mcp")
        true
      rescue Errno::EADDRINUSE
        @log.error("port #{@port} is already in use; run SkRubyMcp::Settings.set('port', <number>) and start again")
        false
      rescue StandardError => error
        close_listener
        @log.error("cannot start on #{@host}:#{@port}: #{error.class}: #{error.message}")
        false
      end

      def stop
        return false unless @running

        @running = false
        @scheduler.cancel
        @connections.each(&:close)
        @connections.clear
        close_listener
        @log.info("stopped after #{uptime_s}s: #{@stats[:requests]} requests, #{@stats[:errors]} errors")
        true
      end

      def health
        {
          ok: true,
          name: SERVER_NAME,
          version: VERSION,
          port: @port,
          uptime_s: uptime_s,
          requests: @stats[:requests],
          errors: @stats[:errors],
          ticks: @stats[:ticks],
          connections: @connections.size
        }
      end

      # Один такт таймера: принять новые соединения, продвинуть чтение, ответить на готовые запросы.
      def tick
        return unless @running

        @stats[:ticks] += 1
        now = Clock.now
        accept_connections(now)
        settle_connections(now)
      rescue StandardError, ScriptError => error
        @stats[:errors] += 1
        @log.error("tick failed: #{error.class}: #{error.message}")
      end

      private

      def accept_connections(now)
        @limits.accepts_per_tick.times do
          break if @connections.size >= @limits.max_connections

          socket = @listener.accept_nonblock(exception: false)
          break if socket == :wait_readable

          @socket_options.configure_client_socket(socket)
          @connections << HttpConnection.new(socket, limits: @connection_limits, now: now)
        end
      rescue IOError, SystemCallError => error
        @log.warn("accept failed: #{error.class}: #{error.message}") if @running
      end

      def settle_connections(now)
        settled = []
        @connections.each do |connection|
          break if settled.size >= @limits.settlements_per_tick

          settled << connection if settle(connection, now)
        end
        @connections -= settled
      end

      # true, если соединение получило ответ или закрылось и его можно забыть.
      def settle(connection, now)
        case connection.pump(now)
        when :complete then respond(connection, handle(connection.request))
        when :rejected then respond(connection, connection.rejection)
        when :closed then connection.close
        else return false
        end
        true
      end

      def respond(connection, response)
        delivered = connection.send_response(response)
        @log.debug("#{response.status} #{delivered ? 'sent' : 'not delivered'}")
        connection.close
      end

      def handle(request)
        @stats[:requests] += 1
        @request_handler.call(request)
      rescue StandardError, ScriptError => error
        @stats[:errors] += 1
        @log.error("request failed: #{error.class}: #{error.message}")
        HttpResponse.json(500, { error: "#{error.class}: #{error.message}" })
      end

      def close_listener
        @listener.close if @listener && !@listener.closed?
      rescue IOError
        nil
      ensure
        @listener = nil
      end

      def uptime_s
        @started_at ? (Clock.now - @started_at).round : 0
      end

      def reset_stats
        @stats = { requests: 0, errors: 0, ticks: 0 }
      end
    end
  end
end
