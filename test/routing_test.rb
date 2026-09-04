# frozen_string_literal: true

require_relative 'test_helper'

class RouterTest < Minitest::Test
  Router = SkRubyMcp::Transport::Router
  HttpRequest = SkRubyMcp::Transport::HttpRequest
  HttpResponse = SkRubyMcp::Transport::HttpResponse

  def setup
    @router = Router.new
                    .add('POST', '/mcp', ->(request) { HttpResponse.json(200, { echoed: request.body }) })
                    .add('GET', '/health', ->(_request) { HttpResponse.json(200, { ok: true }) })
  end

  def request(method, path)
    HttpRequest.new(method: method, path: path, headers: {}, body: 'payload')
  end

  def test_dispatches_to_the_matching_handler
    assert_equal '{"echoed":"payload"}', @router.call(request('POST', '/mcp')).body
  end

  def test_unknown_path_is_404
    assert_equal 404, @router.call(request('GET', '/nowhere')).status
  end

  def test_wrong_method_is_405_with_allow_header
    response = @router.call(request('GET', '/mcp'))
    assert_equal 405, response.status
    assert_equal 'POST', response.headers['Allow']
    assert_equal 405, @router.call(request('DELETE', '/mcp')).status
  end
end

class LoopbackGuardTest < Minitest::Test
  LoopbackGuard = SkRubyMcp::Transport::LoopbackGuard
  HttpRequest = SkRubyMcp::Transport::HttpRequest

  def request(headers)
    HttpRequest.new(method: 'POST', path: '/mcp', headers: headers, body: '')
  end

  def test_loopback_hosts_are_accepted_case_insensitively
    guard = LoopbackGuard.new
    %w[127.0.0.1 127.0.0.1:7891 localhost LOCALHOST:7891 [::1]:7891].each do |host|
      assert_nil guard.check(request('host' => host)), host
    end
  end

  def test_missing_or_foreign_host_is_forbidden
    guard = LoopbackGuard.new
    assert_equal 403, guard.check(request({})).status
    assert_equal 403, guard.check(request('host' => 'evil.example:7891')).status
    assert_equal 403, guard.check(request('host' => '127.0.0.1.evil.example')).status
  end

  def test_origin_must_be_loopback_when_present
    guard = LoopbackGuard.new
    assert_nil guard.check(request('host' => '127.0.0.1', 'origin' => 'http://localhost:6274'))
    assert_equal 403, guard.check(request('host' => '127.0.0.1', 'origin' => 'https://evil.example')).status
    assert_equal 403, guard.check(request('host' => '127.0.0.1', 'origin' => 'null')).status
  end

  def test_bearer_token_is_enforced_only_when_configured
    open_guard = LoopbackGuard.new(token: '')
    assert_nil open_guard.check(request('host' => '127.0.0.1'))

    guard = LoopbackGuard.new(token: 'secret')
    denied = guard.check(request('host' => '127.0.0.1'))
    assert_equal 401, denied.status
    assert_equal 'Bearer', denied.headers['WWW-Authenticate']
    assert_equal 401, guard.check(request('host' => '127.0.0.1', 'authorization' => 'Bearer wrong')).status
    assert_nil guard.check(request('host' => '127.0.0.1', 'authorization' => 'Bearer secret'))
  end
end

class McpEndpointTest < Minitest::Test
  McpEndpoint = SkRubyMcp::Transport::McpEndpoint
  HttpRequest = SkRubyMcp::Transport::HttpRequest

  def setup
    handler = SkRubyMcp::Protocol::McpHandler.new(tools: [], server_info: { name: 's', version: '1' }, instructions: '')
    @endpoint = McpEndpoint.new(handler: handler)
  end

  def post(body, headers = {})
    @endpoint.call(HttpRequest.new(method: 'POST', path: '/mcp', headers: headers, body: body))
  end

  def test_requests_get_json_results
    response = post(TestSupport.json_rpc('ping'))
    assert_equal 200, response.status
    assert_equal 'application/json; charset=utf-8', response.headers['Content-Type']
    assert_equal({ 'jsonrpc' => '2.0', 'id' => 1, 'result' => {} }, JSON.parse(response.body))
  end

  def test_notifications_get_202_without_body
    response = post('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    assert_equal 202, response.status
    assert_equal '', response.body
  end

  def test_parse_and_invalid_request_errors_are_400
    assert_equal 400, post('garbage').status
    assert_equal 400, post('[]').status
    body = JSON.parse(post('garbage').body)
    assert_equal(-32_700, body['error']['code'])
  end

  def test_method_errors_stay_200
    response = post(TestSupport.json_rpc('unknown/method'))
    assert_equal 200, response.status
    assert_equal(-32_601, JSON.parse(response.body)['error']['code'])
  end

  def test_protocol_version_header_is_validated
    assert_equal 200, post(TestSupport.json_rpc('ping'), 'mcp-protocol-version' => '2025-06-18').status
    response = post(TestSupport.json_rpc('ping'), 'mcp-protocol-version' => '1999-01-01')
    assert_equal 400, response.status
    assert_includes JSON.parse(response.body)['error']['message'], '1999-01-01'
  end

  def test_invalid_utf8_body_is_a_clean_400
    response = post("\xFF\xFE".b)
    assert_equal 400, response.status
  end
end
