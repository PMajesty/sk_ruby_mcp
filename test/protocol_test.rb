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

  def test_null_id_is_a_request_and_gets_a_reply
    message = JsonRpc.parse('{"jsonrpc":"2.0","id":null,"method":"ping"}')
    assert message.request?
    refute message.notification?
    assert_nil message.id
    response = JsonRpc.success(message.id, {})
    assert_nil response[:id]
    assert_equal({}, response[:result])
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
    assert_equal({ tools: {}, resources: {} }, result[:capabilities])
    assert_equal({ name: 'srv', version: '1' }, result[:serverInfo])
    assert_equal 'hi', result[:instructions]
  end

  def test_initialize_falls_back_to_latest_for_unknown_versions
    result = handle('initialize', { 'protocolVersion' => '2099-01-01' })[:result]
    assert_equal McpHandler::LATEST_PROTOCOL_VERSION, result[:protocolVersion]
  end

  def test_ping_and_defensive_empty_lists
    assert_equal({}, handle('ping')[:result])
    listed = handle('resources/list')[:result]
    assert_equal 1, listed[:resources].size
    assert_equal 'skmcp://howto', listed[:resources].first[:uri]
    assert_equal({ prompts: [] }, handle('prompts/list')[:result])
    assert_equal({ resourceTemplates: [] }, handle('resources/templates/list')[:result])
  end

  def test_resources_read_returns_the_howto
    response = handle('resources/read', { 'uri' => 'skmcp://howto' })
    text = response[:result][:contents].first[:text]
    assert_includes text, 'if_unsaved'
    assert_includes text, '45.degrees'
    assert_includes text, 'model_look'
    assert_includes text, 'named architect and facade helpers'
    unknown = handle('resources/read', { 'uri' => 'skmcp://missing' })
    assert_equal SkRubyMcp::Protocol::JsonRpc::INVALID_PARAMS, unknown[:error][:code]
    assert_equal 1, unknown[:id]
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

  def test_tool_exceptions_become_is_error_results
    response = handle('tools/call', { 'name' => 'echo', 'arguments' => { 'explode' => true } }, id: 3)
    refute response.key?(:error)
    assert_equal 3, response[:id]
    result = response[:result]
    assert result[:isError]
    text = result[:content].first[:text]
    assert_includes text, 'A tool failed'
    assert_includes text, 'model_status'
  end

  def test_cancel_of_another_id_does_not_release_a_parked_gate
    gate = SkRubyMcp::Runtime::ToolCallGate.new
    slow = Class.new do
      def name
        'model_open'
      end

      def spec
        { name: 'model_open' }
      end

      def call(_arguments)
        SkRubyMcp::Runtime::Deferred.new(
          deadline_s: 5,
          poll: -> { nil },
          timeout_result: -> { { content: [{ type: 'text', text: 'opening' }], isError: false } }
        )
      end
    end.new
    cancelled = []
    handler = McpHandler.new(
      tools: [slow, @tool],
      server_info: { name: 'srv', version: '1' },
      instructions: 'hi',
      call_gate: gate,
      on_cancel: ->(request_id) { cancelled << request_id }
    )
    parked = handler.handle(TestSupport.json_rpc('tools/call', { 'name' => 'model_open', 'arguments' => {} }, id: 7))
    assert_instance_of SkRubyMcp::Runtime::Deferred, parked
    handler.on_cancel = lambda do |request_id|
      cancelled << request_id
      parked.release_gate if request_id == 7
    end
    assert_nil handler.handle('{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":8}}')
    assert_equal [8], cancelled
    busy = handler.handle(TestSupport.json_rpc('tools/call', { 'name' => 'echo', 'arguments' => { 'text' => 'yo' } }))
    assert busy[:result][:isError]
    assert_includes busy[:result][:content].first[:text], 'busy'
    assert_nil handler.handle('{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}')
    assert_equal [8, 7], cancelled
    response = handler.handle(TestSupport.json_rpc('tools/call', { 'name' => 'echo', 'arguments' => { 'text' => 'yo' } }))
    refute response[:result][:isError]
  end

  def test_mutating_tool_is_busy_when_the_gate_is_held
    gate = SkRubyMcp::Runtime::ToolCallGate.new
    gate.try_mutating
    handler = McpHandler.new(
      tools: [@tool],
      server_info: { name: 'srv', version: '1' },
      instructions: 'hi',
      call_gate: gate
    )
    response = handler.handle(TestSupport.json_rpc('tools/call', { 'name' => 'echo', 'arguments' => { 'text' => 'yo' } }))
    assert response[:result][:isError]
    assert_includes response[:result][:content].first[:text], 'busy'
    assert_nil @tool.received
  end

  def test_begin_tick_releases_the_gate
    gate = SkRubyMcp::Runtime::ToolCallGate.new
    gate.try_mutating
    gate.begin_tick
    handler = McpHandler.new(
      tools: [@tool],
      server_info: { name: 'srv', version: '1' },
      instructions: 'hi',
      call_gate: gate
    )
    response = handler.handle(TestSupport.json_rpc('tools/call', { 'name' => 'echo', 'arguments' => { 'text' => 'yo' } }))
    refute response[:result][:isError]
    assert_equal 'yo', response[:result][:content].first[:text]
  end

  def test_model_status_is_answered_when_the_gate_is_held
    gate = SkRubyMcp::Runtime::ToolCallGate.new
    gate.try_mutating
    status = StatusTool.new
    handler = McpHandler.new(
      tools: [@tool, status],
      server_info: { name: 'srv', version: '1' },
      instructions: 'hi',
      call_gate: gate
    )
    response = handler.handle(TestSupport.json_rpc('tools/call', { 'name' => 'model_status' }))
    refute response[:result][:isError]
    assert_equal 'ok: true', response[:result][:content].first[:text]
    assert status.called
  end

  class StatusTool
    attr_reader :called

    def initialize
      @called = false
    end

    def name
      'model_status'
    end

    def spec
      { name: 'model_status', annotations: { readOnlyHint: false } }
    end

    def polls_while_busy?
      true
    end

    def call(_arguments)
      @called = true
      { content: [{ type: 'text', text: 'ok: true' }], isError: false }
    end
  end
end
