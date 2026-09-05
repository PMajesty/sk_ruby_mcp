# frozen_string_literal: true

require_relative 'test_helper'

class ExecuteRubyToolTest < Minitest::Test
  ExecuteRuby = SkRubyMcp::Tools::ExecuteRuby

  def setup
    @executor = TestSupport::SpyExecutor.new(TestSupport.execution_result)
    @session = TestSupport::QuietSession.new
    @tool = ExecuteRuby.new(
      executor: @executor,
      session: @session,
      host_info: { sketchup: '22.0.354', ruby: '2.7.2', platform: 'mac' }
    )
  end

  def parsed(result)
    JSON.parse(result[:content].first[:text])
  end

  def test_spec_describes_a_destructive_tool_with_code_required
    spec = @tool.spec
    assert_equal 'execute_ruby', spec[:name]
    assert_equal ['code'], spec[:inputSchema][:required]
    assert_equal true, spec[:annotations][:destructiveHint]
    assert_equal false, spec[:annotations][:openWorldHint]
    assert spec.key?(:outputSchema)
    refute spec[:inputSchema][:properties].key?(:ensure_model)
    text = spec[:description]
    assert_includes text, 'Host: SketchUp 22.0.354, Ruby 2.7.2, mac'
    assert_includes text, 'Ruby 2.7: no Hash#except'
    assert_includes text, 'pushpull follows the front normal'
    assert_includes text, 'make_unique'
    assert_includes text, '10.m'
    assert_includes text, 'edit_context'
    assert_includes text, 'Vector3d'
    assert_includes text, 'one opening'
  end

  def test_unknown_ensure_model_is_an_argument_error
    result = @tool.call('code' => '1', 'ensure_model' => true)
    assert result[:isError]
    assert_equal 'unknown_arguments', parsed(result)['error']
    refute parsed(result).key?('instead')
    assert_includes parsed(result)['next'], 'documented arguments'
    assert_empty @executor.calls
  end

  def test_missing_code_is_a_tool_error_without_calling_the_executor
    result = @tool.call({})
    assert result[:isError]
    assert_equal 'unknown_arguments', parsed(result)['error']
    assert_empty @executor.calls
  end

  def test_defaults_wrap_in_operation_and_operation_name
    @tool.call('code' => '1 + 1')
    assert_equal [['1 + 1', 'MCP execute_ruby', true, nil]], @executor.calls
  end

  def test_successful_result_is_structured_json
    result = @tool.call('code' => '1 + 1')
    refute result[:isError]
    body = parsed(result)
    assert_equal true, body['ok']
    assert_equal '2', body['return_value']
    assert_equal false, body['truncated']
    assert_equal result[:structuredContent], body
  end

  def test_unknown_arguments_are_rejected_without_calling_the_executor
    result = @tool.call('code' => '1', 'bogus_ignored_arg' => 123, 'also_extra' => true)
    assert result[:isError]
    assert_includes parsed(result)['message'], 'also_extra'
    assert_empty @executor.calls
  end

  def test_truncated_true_is_in_json
    result = ExecuteRuby.new(
      executor: TestSupport::SpyExecutor.new(TestSupport.execution_result(truncated: true)),
      session: @session
    ).call('code' => 'x')
    assert_equal true, parsed(result)['truncated']
  end

  def test_failed_execution_renders_ruby_error
    failure = TestSupport.execution_result(
      ok: false, return_value: nil, stdout: "partial\n",
      error: { class: 'NameError', message: 'undefined x', backtrace: ['(execute_ruby):1:in `<main>`'] }
    )
    result = ExecuteRuby.new(executor: TestSupport::SpyExecutor.new(failure), session: @session).call('code' => 'x')
    body = parsed(result)
    assert result[:isError]
    assert_equal 'ruby_error', body['error']
    assert_equal 'undefined x', body['message']
    assert_equal '(execute_ruby):1:in `<main>`', body['ruby']['backtrace'].first
    refute body.key?('instead')
    refute body.key?('next')
  end

  def test_edit_context_is_in_json
    result = ExecuteRuby.new(
      executor: TestSupport::SpyExecutor.new(TestSupport.execution_result(edit_context: 'root')),
      session: @session
    ).call('code' => '1')
    assert_equal 'root', parsed(result)['edit_context']
  end

  def test_pending_document_blocks_execute_ruby
    session = Object.new
    def session.ruby_refusal
      {
        class: 'DocumentOpening',
        message: 'A document operation is still opening.',
        next: 'Call model_status.',
        model_present: false
      }
    end
    result = ExecuteRuby.new(executor: @executor, session: session).call('code' => '1')
    assert result[:isError]
    assert_includes parsed(result)['message'], 'still opening'
    assert_empty @executor.calls
  end

  def test_missing_model_names_model_status
    failure = TestSupport.execution_result(
      ok: false, return_value: nil, model_present: false,
      error: { class: 'NoActiveModel', message: 'No focused SketchUp document.', backtrace: [] }
    )
    session = Object.new
    def session.ruby_refusal
      nil
    end
    def session.empty_document_next
      'Call model_new from the session double.'
    end
    result = ExecuteRuby.new(
      executor: TestSupport::SpyExecutor.new(failure),
      session: session
    ).call('code' => 'x')
    body = parsed(result)
    assert_equal 'no_document', body['error']
    refute body.key?('instead')
    assert_includes body['next'], 'model_new'
  end

  def test_timeout_and_refused_and_scope_reset_and_forwarded_args
    timeout = TestSupport.execution_result(
      ok: false, return_value: nil,
      error: { class: 'Timeout::Error', message: 'execution exceeded 2 s', backtrace: [] }
    )
    timeout_body = parsed(ExecuteRuby.new(executor: TestSupport::SpyExecutor.new(timeout), session: @session).call('code' => 'x'))
    assert_equal 'timeout', timeout_body['error']
    refute timeout_body.key?('instead')
    assert_includes timeout_body['next'], 'one opening'

    refused = TestSupport.execution_result(
      ok: false, return_value: nil,
      error: { class: 'SkRubyMcp::Runtime::RefusedCall', message: 'system is refused', backtrace: [] }
    )
    refused_body = parsed(ExecuteRuby.new(executor: TestSupport::SpyExecutor.new(refused), session: @session).call('code' => 'x'))
    assert_equal 'refused_call', refused_body['error']

    reset = TestSupport.execution_result(scope_reset: true)
    reset_body = parsed(ExecuteRuby.new(executor: TestSupport::SpyExecutor.new(reset), session: @session).call('code' => '1'))
    assert_includes reset_body['next'], 'locals'
    assert SchemaCheck.valid?(SkRubyMcp::Tools::EXECUTE_OUTPUT_SCHEMA, reset_body)

    untitled = TestSupport.execution_result(model_path: nil, model_title: 'Untitled')
    untitled_body = parsed(ExecuteRuby.new(executor: TestSupport::SpyExecutor.new(untitled), session: @session).call('code' => '1'))
    assert untitled_body.key?('path')
    assert_nil untitled_body['path']
    assert SchemaCheck.valid?(SkRubyMcp::Tools::EXECUTE_OUTPUT_SCHEMA, untitled_body)

    @tool.call('code' => '1', 'timeout_s' => 12, 'wrap_in_operation' => false)
    assert_equal [['1', 'MCP execute_ruby', false, 12.0]], @executor.calls
  end
end
