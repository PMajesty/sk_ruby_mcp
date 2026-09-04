# frozen_string_literal: true

require_relative 'test_helper'

class HttpServerTest < Minitest::Test
  HttpServer = SkRubyMcp::Transport::HttpServer
  HttpConnection = SkRubyMcp::Transport::HttpConnection
  HttpResponse = SkRubyMcp::Transport::HttpResponse

  def setup
    @port = TestSupport.free_port
    @scheduler = TestSupport::ManualScheduler.new
    @log = TestSupport::RecordingLog.new
    @handler = ->(request) { HttpResponse.json(200, { path: request.path, body: request.body }) }
    @server = build_server
  end

  def teardown
    @server.stop
  end

  def build_server(handler: @handler, connection_limits: HttpConnection::DEFAULT_LIMITS)
    HttpServer.new(
      host: '127.0.0.1', port: @port, pump_interval: 0.05, request_handler: handler,
      scheduler: @scheduler, log: @log, connection_limits: connection_limits
    )
  end

  def open_client(raw = nil)
    client = TCPSocket.new('127.0.0.1', @port)
    client.write(raw) if raw
    client
  end

  def wait_for_bytes(client, attempts: 50)
    attempts.times do
      return true if IO.select([client], nil, nil, 0.02)

      @scheduler.tick!
    end
    false
  end

  def exchange(raw)
    client = open_client(raw)
    @scheduler.tick!
    wait_for_bytes(client)
    TestSupport.parse_response(client.read)
  ensure
    client&.close
  end

  def test_start_binds_and_schedules_the_pump
    assert @server.start
    assert @server.running?
    assert_equal 0.05, @scheduler.interval
    assert_equal 0, @server.stats[:requests]
  end

  def test_serves_a_request_within_a_tick
    @server.start
    status, headers, body = exchange(TestSupport.http_request('POST', '/mcp', body: 'hi'))
    assert_equal 200, status
    assert_equal 'close', headers['connection']
    assert_equal({ 'path' => '/mcp', 'body' => 'hi' }, JSON.parse(body))
    assert_equal 1, @server.stats[:requests]
    assert_equal 0, @server.stats[:errors]
  end

  def test_several_clients_are_served_in_one_tick
    @server.start
    clients = Array.new(3) { |index| open_client(TestSupport.http_request('GET', "/c#{index}")) }
    sleep 0.05
    @scheduler.tick!
    clients.each_with_index do |client, index|
      wait_for_bytes(client)
      status, _headers, body = TestSupport.parse_response(client.read)
      assert_equal 200, status
      assert_equal "/c#{index}", JSON.parse(body)['path']
      client.close
    end
    assert_equal 3, @server.stats[:requests]
  end

  def test_handler_failures_become_500_and_are_counted
    @server = build_server(handler: ->(_request) { raise 'kaboom' })
    @server.start
    status, _headers, body = exchange(TestSupport.http_request('GET', '/health'))
    assert_equal 500, status
    assert_includes body, 'kaboom'
    assert_equal 1, @server.stats[:errors]
    assert @log.messages.any? { |level, message| level == :error && message.include?('kaboom') }
  end

  def test_silent_client_gets_408_and_does_not_block_others
    limits = HttpConnection::Limits.new(max_header_bytes: 16_384, max_body_bytes: 1024, read_deadline_s: 0.05, write_deadline_s: 0.5)
    @server = build_server(connection_limits: limits)
    @server.start
    silent = open_client
    @scheduler.tick!
    status, = exchange(TestSupport.http_request('GET', '/health'))
    assert_equal 200, status
    sleep 0.06
    @scheduler.tick!
    wait_for_bytes(silent)
    silent_status, = TestSupport.parse_response(silent.read)
    assert_equal 408, silent_status
    silent.close
  end

  def test_stop_closes_the_listener_and_cancels_the_timer
    @server.start
    assert @server.stop
    refute @server.running?
    assert @scheduler.cancelled
    assert_raises(Errno::ECONNREFUSED) { TCPSocket.new('127.0.0.1', @port) }
    assert @server.start, 'restart after stop must work'
  end

  def test_start_is_idempotent
    assert @server.start
    assert @server.start
    assert_equal 1, @log.messages.count { |_level, message| message.include?('listening') }
  end

  def test_port_in_use_is_reported_not_raised
    blocker = TCPServer.new('127.0.0.1', @port)
    refute @server.start
    refute @server.running?
    assert @log.messages.any? { |level, message| level == :error && message.include?('already in use') }
  ensure
    blocker.close
  end

  def test_health_reports_identity_and_counters
    @server.start
    health = @server.health
    assert_equal SkRubyMcp::SERVER_NAME, health[:name]
    assert_equal SkRubyMcp::VERSION, health[:version]
    assert_equal @port, health[:port]
    assert_equal 0, health[:requests]
  end

  def test_tick_without_clients_is_harmless
    @server.start
    5.times { @scheduler.tick! }
    assert_equal 5, @server.stats[:ticks]
  end
end
