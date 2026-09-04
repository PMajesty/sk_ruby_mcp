# frozen_string_literal: true

require_relative 'test_helper'

class JsonRpcTest < Minitest::Test
  JsonRpc = SkRubyMcp::Protocol::JsonRpc

  def test_parses_a_request
    message = JsonRpc.parse('{"jsonrpc":"2.0","id":7,"method":"ping","params":{"a":1}}')
    assert message.request?
    assert_equal 7, message.id
    assert_equal 'ping', message.method
    assert_equal({ 'a' => 1 }, message.params)
  end

  def test_recognises_notifications_and_client_responses
    assert JsonRpc.parse('{"jsonrpc":"2.0","method":"notifications/initialized"}').notification?
    assert JsonRpc.parse('{"jsonrpc":"2.0","id":1,"result":{}}').response?
  end

  def test_invalid_json_is_a_parse_error
    error = assert_raises(JsonRpc::ProtocolError) { JsonRpc.parse('{not json') }
    assert_equal JsonRpc::PARSE_ERROR, error.code
    assert_nil error.id
  end

  def test_batches_are_rejected
    error = assert_raises(JsonRpc::ProtocolError) { JsonRpc.parse('[{"jsonrpc":"2.0","id":1,"method":"ping"}]') }
    assert_equal JsonRpc::INVALID_REQUEST, error.code
  end

  def test_wrong_version_keeps_the_id_for_the_error_reply
    error = assert_raises(JsonRpc::ProtocolError) { JsonRpc.parse('{"jsonrpc":"1.0","id":"abc","method":"ping"}') }
    assert_equal JsonRpc::INVALID_REQUEST, error.code
    assert_equal 'abc', error.id
  end

  def test_method_and_params_types_are_validated
    assert_raises(JsonRpc::ProtocolError) { JsonRpc.parse('{"jsonrpc":"2.0","id":1,"method":5}') }
    assert_raises(JsonRpc::ProtocolError) { JsonRpc.parse('{"jsonrpc":"2.0","id":1,"method":"ping","params":[1]}') }
    assert_raises(JsonRpc::ProtocolError) { JsonRpc.parse('{"jsonrpc":"2.0","id":{},"method":"ping"}') }
    assert_raises(JsonRpc::ProtocolError) { JsonRpc.parse('"just a string"') }
  end

  def test_envelopes
    assert_equal({ jsonrpc: '2.0', id: 1, result: { ok: true } }, JsonRpc.success(1, { ok: true }))
    assert_equal({ jsonrpc: '2.0', id: nil, error: { code: -32_601, message: 'nope' } }, JsonRpc.error(nil, -32_601, 'nope'))
  end
end

class McpHandlerTest < Minitest::Test
  McpHandler = SkRubyMcp::Protocol::McpHandler

  class EchoTool
    attr_reader :received

    def name
      'echo'
    end

    def spec
      { name: 'echo', inputSchema: { type: 'object' } }
    end

    def call(arguments)
      @received = arguments
      raise 'tool exploded' if arguments['explode']

      { content: [{ type: 'text', text: arguments['text'].to_s }], isError: false }
    end
  end

  def setup
    @tool = EchoTool.new
    @handler = McpHandler.new(tools: [@tool], server_info: { name: 'srv', version: '1' }, instructions: 'hi')
  end

  def handle(method, params = nil, id: 1)
    @handler.handle(TestSupport.json_rpc(method, params, id: id))
  end

  def test_initialize_echoes_a_supported_version
    result = handle('initialize', { 'protocolVersion' => '2025-03-26', 'capabilities' => {} })[:result]
    assert_equal '2025-03-26', result[:protocolVersion]
    assert_equal({ tools: {} }, result[:capabilities])
    assert_equal({ name: 'srv', version: '1' }, result[:serverInfo])
    assert_equal 'hi', result[:instructions]
  end

  def test_initialize_falls_back_to_latest_for_unknown_versions
    result = handle('initialize', { 'protocolVersion' => '2099-01-01' })[:result]
    assert_equal McpHandler::LATEST_PROTOCOL_VERSION, result[:protocolVersion]
  end

  def test_ping_and_defensive_empty_lists
    assert_equal({}, handle('ping')[:result])
    assert_equal({ resources: [] }, handle('resources/list')[:result])
    assert_equal({ prompts: [] }, handle('prompts/list')[:result])
    assert_equal({ resourceTemplates: [] }, handle('resources/templates/list')[:result])
  end

  def test_tools_list_returns_specs
    assert_equal({ tools: [@tool.spec] }, handle('tools/list', { 'cursor' => nil })[:result])
  end

  def test_tools_call_passes_string_keyed_arguments
    response = handle('tools/call', { 'name' => 'echo', 'arguments' => { 'text' => 'yo' } }, id: 'call-1')
    assert_equal 'call-1', response[:id]
    assert_equal 'yo', response[:result][:content].first[:text]
    assert_equal({ 'text' => 'yo' }, @tool.received)
  end

  def test_tools_call_without_arguments_passes_an_empty_hash
    handle('tools/call', { 'name' => 'echo' })
    assert_equal({}, @tool.received)
  end

  def test_unknown_tool_is_invalid_params
    response = handle('tools/call', { 'name' => 'missing' })
    assert_equal SkRubyMcp::Protocol::JsonRpc::INVALID_PARAMS, response[:error][:code]
    assert_equal 1, response[:id]
  end

  def test_unknown_method_is_method_not_found
    response = handle('logging/setLevel', { 'level' => 'debug' }, id: 9)
    assert_equal SkRubyMcp::Protocol::JsonRpc::METHOD_NOT_FOUND, response[:error][:code]
    assert_equal 9, response[:id]
  end

  def test_notifications_and_client_responses_get_no_reply
    assert_nil @handler.handle('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    assert_nil @handler.handle('{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}')
    assert_nil @handler.handle('{"jsonrpc":"2.0","id":5,"result":{}}')
  end

  def test_parse_errors_become_error_replies
    response = @handler.handle('nope')
    assert_equal SkRubyMcp::Protocol::JsonRpc::PARSE_ERROR, response[:error][:code]
    assert_nil response[:id]
  end

  def test_tool_exceptions_become_internal_errors_with_the_request_id
    response = handle('tools/call', { 'name' => 'echo', 'arguments' => { 'explode' => true } }, id: 3)
    assert_equal SkRubyMcp::Protocol::JsonRpc::INTERNAL_ERROR, response[:error][:code]
    assert_includes response[:error][:message], 'tool exploded'
    assert_equal 3, response[:id]
  end
end
