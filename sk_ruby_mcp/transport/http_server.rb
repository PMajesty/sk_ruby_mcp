# frozen_string_literal: true

require 'socket'
require 'timeout'

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
      MAX_PARKED = 4

      attr_reader :host, :port, :stats

      def initialize(host:, port:, pump_interval:, request_handler:, scheduler:, log:,
                     limits: DEFAULT_LIMITS, connection_limits: HttpConnection::DEFAULT_LIMITS,
                     socket_options: Platform, on_tick_begin: nil, hosts: nil)
        @hosts = Array(hosts || [host])
        @host = @hosts.first
        @port = port
        @pump_interval = pump_interval
        @request_handler = request_handler
        @scheduler = scheduler
        @log = log
        @limits = limits
        @connection_limits = connection_limits
        @socket_options = socket_options
        @on_tick_begin = on_tick_begin
        @connections = []
        @listeners = []
        @running = false
        @started_at = nil
        @last_tick_at = nil
        @ticking = false
        @ipv6_warned = false
        reset_stats
      end

      def running?
        @running
      end

      def start
        return true if @running

        @hosts.each do |bind_host|
          next if listen_on(bind_host)
          return false unless ipv6_bind?(bind_host)
        end
        if @listeners.empty?
          @log.error("cannot start on #{@host}:#{@port}: no listeners")
          return false
        end

        @started_at = Clock.now
        reset_stats
        @scheduler.every(@pump_interval) { tick }
        @running = true
        true
      end

      def drop_parked(request_id)
        doomed = @connections.select do |connection|
          connection.parked? && connection.deferred && same_rpc_id?(connection.deferred.rpc_id, request_id)
        end
        return false if doomed.empty?

        doomed.each(&:close)
        @connections -= doomed
        true
      end

      def stop
        return false unless @running

        @running = false
        @scheduler.cancel
        @connections.each(&:close)
        @connections.clear
        close_listeners
        @log.info("stopped after #{uptime_s}s: #{@stats[:requests]} requests, #{@stats[:errors]} errors")
        true
      end

      def restart_pump
        return false unless @running

        @scheduler.every(@pump_interval) { tick }
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
          transport_errors: @stats[:errors],
          ticks: @stats[:ticks],
          last_tick_age_ms: last_tick_age_ms,
          connections: @connections.size
        }
      end

      # Один такт таймера: принять новые соединения, продвинуть чтение, ответить на готовые запросы.
      def tick
        return unless @running
        return if @ticking

        @ticking = true
        begin
          @stats[:ticks] += 1
          @last_tick_at = Clock.now
          now = @last_tick_at
          @on_tick_begin.call if @on_tick_begin
          accept_connections(now)
          settle_connections(now)
        rescue StandardError, ScriptError, Timeout::Error, Interrupt => error
          @stats[:errors] += 1
          @log.error("tick failed: #{error.class}: #{error.message}")
        ensure
          @ticking = false
        end
      end

      private

      def accept_connections(now)
        @listeners.each do |listener|
          @limits.accepts_per_tick.times do
            break if @connections.size >= @limits.max_connections

            socket = listener.accept_nonblock(exception: false)
            break if socket == :wait_readable

            @socket_options.configure_client_socket(socket)
            @connections << HttpConnection.new(socket, limits: @connection_limits, now: now)
          end
        end
      rescue IOError, SystemCallError => error
        @log.warn("accept failed: #{error.class}: #{error.message}") if @running
      end

      def settle_connections(now)
        settled = []
        priority, rest = @connections.partition { |connection| connection.parked? || connection.writing? }
        priority.each do |connection|
          settled << connection if settle(connection, now)
        end
        rest.each do |connection|
          next if connection.equal?(@in_flight)
          break if settled.size >= @limits.settlements_per_tick

          settled << connection if settle(connection, now)
        end
        @connections -= settled
      end

      # true, если соединение получило ответ или закрылось и его можно забыть.
      def settle(connection, now)
        return finish_write(connection, now) if connection.writing?
        return settle_parked(connection, now) if connection.parked?

        case connection.pump(now)
        when :complete
          @in_flight = connection
          begin
            finish_request(connection, handle(connection.request), now)
          rescue StandardError, ScriptError, Timeout::Error, Interrupt => error
            @stats[:errors] += 1
            @log.error("request failed: #{error.class}: #{error.message}")
            deliver(connection, HttpResponse.json(500, { error: 'Internal transport error' }))
          ensure
            @in_flight = nil
          end
        when :rejected then deliver(connection, connection.rejection)
        when :closed
          connection.close
          true
        else false
        end
      end

      def finish_request(connection, response, now)
        return park_or_resolve(connection, response, now) if response.is_a?(Runtime::Deferred)

        deliver(connection, response)
      end

      def park_or_resolve(connection, deferred, now)
        payload = deferred.resolve(now)
        return finish_deferred(connection, deferred, payload) if payload
        if !deferred.gated? && parked_status_count >= MAX_PARKED
          return finish_deferred(connection, deferred, deferred.abandon_wait)
        end

        connection.park(deferred)
        false
      end

      def settle_parked(connection, now)
        if connection.peer_closed?
          connection.close
          return true
        end

        deferred = connection.deferred
        payload = deferred.resolve(now)
        if payload.nil? && now >= deferred.deadline_at
          payload = deferred.abandon_wait
        end
        return false unless payload

        finish_deferred(connection, deferred, payload)
      rescue StandardError, ScriptError => error
        @stats[:errors] += 1
        @log.error("parked poll failed: #{error.class}: #{error.message}")
        deliver(connection, HttpResponse.json(500, { error: 'Internal transport error' }))
      end

      def finish_deferred(connection, deferred, payload)
        deliver(connection, deferred.http_payload(payload))
      end

      def parked_status_count
        @connections.count { |connection| connection.parked? && connection.deferred && !connection.deferred.gated? }
      end

      def deliver(connection, response)
        unless response.is_a?(HttpResponse)
          @stats[:errors] += 1
          @log.error('deferred payload was not an HTTP response')
          response = HttpResponse.json(500, { error: 'deferred payload was not an HTTP response' })
        end

        result = connection.send_response(response)
        @log.debug("#{response.status} #{result == :complete ? 'sent' : result}")
        finish_write_result(connection, result)
      end

      def finish_write(connection, now)
        finish_write_result(connection, connection.flush_write(now))
      end

      def finish_write_result(connection, result)
        case result
        when :complete
          connection.close
          true
        when :wait
          false
        else
          connection.close
          true
        end
      end

      def handle(request)
        @stats[:requests] += 1
        @request_handler.call(request)
      rescue StandardError, ScriptError, Timeout::Error, Interrupt => error
        @stats[:errors] += 1
        @log.error("request failed: #{error.class}: #{error.message}")
        HttpResponse.json(500, { error: 'Internal transport error' })
      end

      def listen_on(bind_host)
        listener = TCPServer.new(bind_host, @port)
        @listeners << listener
        @log.info("listening on http://#{display_bind(bind_host)}:#{@port}/mcp")
        true
      rescue StandardError => error
        if ipv6_bind?(bind_host)
          warn_ipv6("#{error.class}: #{error.message}")
          true
        else
          close_listeners
          if error.is_a?(Errno::EADDRINUSE)
            @log.error("port #{@port} is already in use; run SkRubyMcp::Settings.set('port', <number>) and start again")
          else
            @log.error("cannot start on #{bind_host}:#{@port}: #{error.class}: #{error.message}")
          end
          false
        end
      end

      def ipv6_bind?(bind_host)
        bind_host.to_s == '::1' || bind_host.to_s == '[::1]'
      end

      def warn_ipv6(detail)
        return if @ipv6_warned

        @ipv6_warned = true
        @log.error("::1 unavailable: #{detail}; continuing on IPv4")
      end

      def display_bind(bind_host)
        ipv6_bind?(bind_host) ? "[::1]" : bind_host
      end

      def same_rpc_id?(left, right)
        left == right || left.to_s == right.to_s
      end

      def close_listeners
        @listeners.each do |listener|
          listener.close unless listener.closed?
        rescue IOError
          nil
        end
        @listeners.clear
      end

      def last_tick_age_ms
        return nil unless @last_tick_at

        ((Clock.now - @last_tick_at) * 1000).round
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
