# frozen_string_literal: true

require_relative 'test_helper'

class HttpConnectionTest < Minitest::Test
  HttpConnection = SkRubyMcp::Transport::HttpConnection
  HttpResponse = SkRubyMcp::Transport::HttpResponse

  def setup
    @client, @server_side = Socket.pair(Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
    @now = 100.0
  end

  def teardown
    [@client, @server_side].each { |socket| socket.close unless socket.closed? }
  end

  def connection(limits: HttpConnection::DEFAULT_LIMITS)
    HttpConnection.new(@server_side, limits: limits, now: @now)
  end

  def send_bytes(bytes)
    @client.write(bytes)
    @client.flush
  end

  def test_complete_post_in_one_write
    conn = connection
    send_bytes(TestSupport.http_request('POST', '/mcp?x=1', body: '{"a":1}', headers: { 'Content-Type' => 'application/json' }))
    assert_equal :complete, conn.pump(@now)
    request = conn.request
    assert_equal 'POST', request.method
    assert_equal '/mcp', request.path
    assert_equal '127.0.0.1', request.headers['host']
    assert_equal 'application/json', request.headers['content-type']
    assert_equal '{"a":1}', request.body
  end

  def test_request_split_across_writes
    conn = connection
    full = TestSupport.http_request('POST', '/mcp', body: 'hello world')
    send_bytes(full[0, 12])
    assert_equal :reading_head, conn.pump(@now)
    send_bytes(full[12, full.bytesize - 20])
    assert_equal :reading_body, conn.pump(@now + 0.1)
    send_bytes(full[full.bytesize - 8, 8])
    assert_equal :complete, conn.pump(@now + 0.2)
    assert_equal 'hello world', conn.request.body
  end

  def test_lf_only_line_endings_and_headers_without_space
    conn = connection
    send_bytes("POST /mcp HTTP/1.1\nHost:localhost:7891\nContent-Length:2\n\nok")
    assert_equal :complete, conn.pump(@now)
    assert_equal 'localhost:7891', conn.request.headers['host']
    assert_equal 'ok', conn.request.body
  end

  def test_duplicate_headers_are_joined
    conn = connection
    send_bytes("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Tag: a\r\nX-Tag: b\r\n\r\n")
    assert_equal :complete, conn.pump(@now)
    assert_equal 'a, b', conn.request.headers['x-tag']
    assert_equal '', conn.request.body
  end

  def test_post_without_content_length_is_rejected_with_411
    conn = connection
    send_bytes("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    assert_equal :rejected, conn.pump(@now)
    assert_equal 411, conn.rejection.status
  end

  def test_chunked_bodies_are_rejected_with_411
    conn = connection
    send_bytes("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n")
    assert_equal :rejected, conn.pump(@now)
    assert_equal 411, conn.rejection.status
  end

  def test_oversized_body_is_rejected_before_reading_it
    limits = HttpConnection::Limits.new(max_header_bytes: 1024, max_body_bytes: 10, read_deadline_s: 5, write_deadline_s: 0.5)
    conn = connection(limits: limits)
    send_bytes("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 11\r\n\r\n")
    assert_equal :rejected, conn.pump(@now)
    assert_equal 413, conn.rejection.status
  end

  def test_huge_headers_are_rejected_with_431
    limits = HttpConnection::Limits.new(max_header_bytes: 64, max_body_bytes: 1024, read_deadline_s: 5, write_deadline_s: 0.5)
    conn = connection(limits: limits)
    send_bytes("GET /health HTTP/1.1\r\nX-Long: #{'a' * 200}")
    assert_equal :rejected, conn.pump(@now)
    assert_equal 431, conn.rejection.status
  end

  def test_complete_oversized_request_line_is_rejected_with_431
    limits = HttpConnection::Limits.new(max_header_bytes: 64, max_body_bytes: 1024, read_deadline_s: 5, write_deadline_s: 0.5)
    conn = connection(limits: limits)
    send_bytes("GET /#{'a' * 200} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    assert_equal :rejected, conn.pump(@now)
    assert_equal 431, conn.rejection.status
  end

  def test_malformed_request_line_and_content_length
    conn = connection
    send_bytes("HELLO\r\n\r\n")
    assert_equal :rejected, conn.pump(@now)
    assert_equal 400, conn.rejection.status

    @client, @server_side = Socket.pair(Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
    conn = connection
    send_bytes("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: abc\r\n\r\n")
    assert_equal :rejected, conn.pump(@now)
    assert_equal 400, conn.rejection.status
  end

  def test_silent_client_times_out_with_408
    conn = connection
    assert_equal :reading_head, conn.pump(@now + 1)
    assert_equal :rejected, conn.pump(@now + HttpConnection::DEFAULT_LIMITS.read_deadline_s + 0.01)
    assert_equal 408, conn.rejection.status
  end

  def test_eof_before_a_full_request_closes_the_connection
    conn = connection
    send_bytes('GET /hea')
    @client.close
    assert_equal :closed, conn.pump(@now)
  end

  def test_send_response_writes_a_full_http_message
    conn = connection
    conn.send_response(HttpResponse.json(200, { ok: true }, headers: { 'X-Extra' => '1' }))
    conn.close
    status, headers, body = TestSupport.parse_response(@client.read)
    assert_equal 200, status
    assert_equal 'close', headers['connection']
    assert_equal body.bytesize.to_s, headers['content-length']
    assert_equal '1', headers['x-extra']
    assert_equal({ 'ok' => true }, JSON.parse(body))
  end

  def test_empty_response_has_zero_length_body
    conn = connection
    conn.send_response(HttpResponse.empty(202))
    conn.close
    status, headers, body = TestSupport.parse_response(@client.read)
    assert_equal 202, status
    assert_equal '0', headers['content-length']
    assert_equal '', body
  end

  def test_expect_100_continue_is_acknowledged_before_the_body
    conn = connection
    send_bytes("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n")
    assert_equal :reading_body, conn.pump(@now)
    assert_equal "HTTP/1.1 100 Continue\r\n\r\n", @client.read_nonblock(100)
    send_bytes('ok')
    assert_equal :complete, conn.pump(@now)
  end

  def test_binary_garbage_in_headers_does_not_raise
    conn = connection
    send_bytes("GET /\xFF\xFE HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".b)
    assert_equal :complete, conn.pump(@now)
    assert conn.request.path.valid_encoding?
  end
end
