#!/usr/bin/env ruby
# frozen_string_literal: true

# Дымовая проверка живого MCP: handshake 2025, tools, health, Origin.
# Только stdlib. Запуск: ruby eval/protocol_smoke.rb

require 'json'
require 'net/http'
require 'uri'
require_relative 'mcp_client'

HOST = ENV.fetch('SK_RUBY_MCP_HOST', '127.0.0.1')
PORT = Integer(ENV.fetch('SK_RUBY_MCP_PORT', '7891'))
PROTOCOL = '2025-11-25'

module ProtocolSmoke
  module_function

  def run
    @failed = 0
    check('initialize 2025-11-25') { initialize! }
    check('notifications/initialized is 202 empty') { initialized_ack }
    check('tools/list') { tools_list }
    check('tools/call model_status') { model_status }
    check('GET /mcp is 405') { get_mcp_is_405 }
    check('GET /health') { health }
    check('Origin evil is 403') { origin_evil }
    check('Origin loopback http is 200') { origin_loopback }
    exit(@failed.zero? ? 0 : 1)
  end

  def check(name)
    yield
    puts "PASS #{name}"
  rescue StandardError => error
    @failed += 1
    puts "FAIL #{name}: #{error.class}: #{error.message}"
  end

  def initialize!
    status, body = post_mcp(
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: 'protocol-smoke', version: '0' } } },
      protocol_version: false
    )
    raise "HTTP #{status}" unless status == 200

    result = JSON.parse(body).fetch('result')
    raise 'missing protocolVersion' unless result['protocolVersion']
    raise 'missing tools capability' unless result.dig('capabilities', 'tools')
    raise 'missing resources capability' unless result.dig('capabilities', 'resources')
  end

  def initialized_ack
    status, body = post_mcp(
      { jsonrpc: '2.0', method: 'notifications/initialized' },
      protocol_version: true
    )
    raise "HTTP #{status} body=#{body.inspect}" unless status == 202 && body.to_s.empty?
  end

  def tools_list
    status, body = post_mcp(
      { jsonrpc: '2.0', id: 2, method: 'tools/list' },
      protocol_version: true
    )
    raise "HTTP #{status}" unless status == 200

    tools = JSON.parse(body).dig('result', 'tools')
    raise 'tools missing' unless tools.is_a?(Array) && !tools.empty?
  end

  def model_status
    status, body = post_mcp(
      { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'model_status', arguments: {} } },
      protocol_version: true
    )
    raise "HTTP #{status}" unless status == 200

    result = JSON.parse(body).fetch('result')
    raise 'model_status missing content' unless result['content'].is_a?(Array)
  end

  def get_mcp_is_405
    response = http_request(Net::HTTP::Get.new(URI("http://#{HOST}:#{PORT}/mcp")))
    raise "HTTP #{response.code}" unless response.code.to_i == 405
  end

  def health
    response = http_request(Net::HTTP::Get.new(URI("http://#{HOST}:#{PORT}/health")))
    raise "HTTP #{response.code}" unless response.code.to_i == 200

    payload = JSON.parse(response.body)
    raise 'health not ok' unless payload['ok'] == true
    raise 'health leaked model fields' if payload.key?('state') || payload.key?('path') || payload.key?('model')
  end

  def origin_evil
    status, _body = post_mcp(
      { jsonrpc: '2.0', id: 4, method: 'ping' },
      protocol_version: true,
      origin: 'http://evil.example'
    )
    raise "HTTP #{status} (expected 403)" unless status == 403
  end

  def origin_loopback
    status, body = post_mcp(
      { jsonrpc: '2.0', id: 5, method: 'ping' },
      protocol_version: true,
      origin: 'http://127.0.0.1:6274'
    )
    raise "HTTP #{status} (expected 200)" unless status == 200

    parsed = JSON.parse(body)
    raise 'ping result missing' unless parsed.key?('result')
  end

  def post_mcp(payload, protocol_version:, origin: nil)
    uri = URI("http://#{HOST}:#{PORT}/mcp")
    request = Net::HTTP::Post.new(uri)
    request['Host'] = "#{HOST}:#{PORT}"
    request['Content-Type'] = 'application/json'
    request['MCP-Protocol-Version'] = PROTOCOL if protocol_version
    request['Origin'] = origin if origin
    request.body = JSON.generate(payload)
    response = http_request(request)
    [response.code.to_i, response.body]
  end

  def http_request(request)
    Net::HTTP.start(HOST, PORT, open_timeout: 3, read_timeout: 20) do |http|
      http.request(request)
    end
  end
end

ProtocolSmoke.run
