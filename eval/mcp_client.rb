# frozen_string_literal: true

# Минимальный клиент Streamable HTTP для живых проверок. Только stdlib.

require 'json'
require 'net/http'
require 'securerandom'
require 'timeout'
require 'uri'

module SkMcpEval
  REFUSED = 'SketchUp is closed or the MCP server is stopped. Start SketchUp and try again.'

  class Error < StandardError; end

  class Client
    PROTOCOL = '2025-11-25'

    def initialize(host: ENV.fetch('SK_RUBY_MCP_HOST', '127.0.0.1'),
                   port: Integer(ENV.fetch('SK_RUBY_MCP_PORT', '7891')),
                   read_timeout: 40)
      @host = host
      @port = port
      @read_timeout = read_timeout
      @protocol = nil
    end

    def initialize!
      status, payload = post(
        { jsonrpc: '2.0', id: 1, method: 'initialize',
          params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: 'sk-mcp-eval', version: '0' } } },
        protocol_version: false
      )
      raise Error, "initialize HTTP #{status}" unless status == 200

      @protocol = payload.fetch('result').fetch('protocolVersion')
      notify('notifications/initialized')
      payload.fetch('result')
    end

    def tools
      _status, payload = rpc('tools/list')
      payload.fetch('result').fetch('tools')
    end

    def call(name, arguments = {})
      _status, payload = rpc('tools/call', { name: name, arguments: arguments })
      payload.fetch('result')
    end

    def read_resource(uri)
      _status, payload = rpc('resources/read', { uri: uri })
      payload.fetch('result')
    end

    def notify(method, params = nil)
      status, body = post({ jsonrpc: '2.0', method: method, params: params }.compact, protocol_version: !@protocol.nil?)
      raise Error, "#{method} HTTP #{status}" unless status == 202 && body.to_s.empty?
    end

    def health
      uri = URI("http://#{@host}:#{@port}/health")
      response = http_request(Net::HTTP::Get.new(uri))
      raise Error, "health HTTP #{response.code}" unless response.code.to_i == 200

      JSON.parse(response.body)
    end

    def post(message, protocol_version:, origin: nil)
      uri = URI("http://#{@host}:#{@port}/mcp")
      request = Net::HTTP::Post.new(uri)
      request['Host'] = "#{@host}:#{@port}"
      request['Content-Type'] = 'application/json'
      request['MCP-Protocol-Version'] = (@protocol || PROTOCOL) if protocol_version
      request['Origin'] = origin if origin
      request.body = JSON.generate(message)
      response = http_request(request)
      body = response.body.to_s
      parsed = body.empty? ? nil : JSON.parse(body)
      [response.code.to_i, parsed, body]
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError
      raise Error, REFUSED
    end

    private

    def rpc(method, params = nil)
      message = { jsonrpc: '2.0', id: SecureRandom.uuid, method: method }
      message[:params] = params if params
      status, payload, raw = post(message, protocol_version: true)
      raise Error, "#{method} HTTP #{status} #{raw}" unless status == 200
      raise Error, "#{method} missing result" unless payload.is_a?(Hash) && payload.key?('result')

      [status, payload]
    end

    def http_request(request)
      Timeout.timeout(@read_timeout + 2) do
        http = Net::HTTP.new(@host, @port)
        http.open_timeout = 3
        http.read_timeout = @read_timeout
        http.write_timeout = 5 if http.respond_to?(:write_timeout=)
        http.start { http.request(request) }
      end
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError
      raise Error, REFUSED
    rescue Timeout::Error
      raise Error, hung_message
    end

    def hung_message
      "SketchUp did not reply in #{@read_timeout}s. A native API call may still be running. " \
        'Poll GET /health until last_tick_age_ms is small, then continue with a smaller execute_ruby.'
    end
  end
end
