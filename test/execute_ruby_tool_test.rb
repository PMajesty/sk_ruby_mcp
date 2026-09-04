# frozen_string_literal: true

require_relative 'test_helper'

class ExecuteRubyToolTest < Minitest::Test
  ExecuteRuby = SkRubyMcp::Tools::ExecuteRuby

  def setup
    @executor = TestSupport::SpyExecutor.new(TestSupport.execution_result)
    @tool = ExecuteRuby.new(executor: @executor)
  end

  def test_spec_describes_a_destructive_open_world_tool_with_code_required
    spec = @tool.spec
    assert_equal 'execute_ruby', spec[:name]
    assert_equal ['code'], spec[:inputSchema][:required]
    assert_equal true, spec[:annotations][:destructiveHint]
    assert_equal true, spec[:annotations][:openWorldHint]
    assert_equal false, spec[:annotations][:readOnlyHint]
    refute spec.key?(:outputSchema)
    assert_includes spec[:description], 'undo'
  end

  def test_missing_code_is_a_tool_error_without_calling_the_executor
    result = @tool.call({})
    assert result[:isError]
    assert_includes result[:content].first[:text], 'error: ArgumentError:'
    assert_empty @executor.calls
  end

  def test_blank_code_is_rejected
    result = @tool.call('code' => "  \n ")
    assert result[:isError]
    assert_includes result[:content].first[:text], 'non-empty'
  end

  def test_defaults_wrap_in_operation_and_operation_name_and_leave_timeout_to_the_executor
    @tool.call('code' => '1 + 1')
    assert_equal [['1 + 1', 'MCP execute_ruby', true, nil]], @executor.calls
  end

  def test_explicit_arguments_are_passed_through
    @tool.call('code' => 'x', 'operation_name' => "  Build roof  ", 'wrap_in_operation' => false, 'timeout_s' => 5)
    assert_equal [['x', 'Build roof', false, 5.0]], @executor.calls
  end

  def test_invalid_timeout_values_fall_back_to_the_default
    @tool.call('code' => 'x', 'timeout_s' => 'soon')
    @tool.call('code' => 'x', 'timeout_s' => -1)
    assert_equal [nil, nil], @executor.calls.map(&:last)
  end

  def test_default_wrap_can_be_disabled_by_configuration
    tool = ExecuteRuby.new(executor: @executor, wrap_in_operation_by_default: false)
    tool.call('code' => 'x')
    assert_equal false, @executor.calls.first[2]
  end

  def test_operation_name_is_bounded
    @tool.call('code' => 'x', 'operation_name' => 'n' * 200)
    assert_equal 80, @executor.calls.first[1].length
  end

  def test_successful_result_is_a_single_text_block
    result = @tool.call('code' => '1 + 1')
    refute result[:isError]
    assert_equal 1, result[:content].size
    assert_equal %i[content isError], result.keys
    assert_includes result[:content].first[:text], 'ok: true'
    assert_includes result[:content].first[:text], 'return_value: 2'
  end

  def test_failed_execution_renders_error_and_backtrace
    failure = TestSupport.execution_result(
      ok: false, return_value: nil, stdout: "partial\n",
      error: { class: 'NameError', message: 'undefined x', backtrace: ['(execute_ruby):1:in `<main>`'] }
    )
    result = ExecuteRuby.new(executor: TestSupport::SpyExecutor.new(failure)).call('code' => 'x')
    text = result[:content].first[:text]
    assert result[:isError]
    assert_includes text, 'error: NameError: undefined x'
    assert_includes text, '(execute_ruby):1'
    assert_includes text, "stdout:\npartial"
  end

  def test_missing_model_is_called_out_in_text
    result = ExecuteRuby.new(executor: TestSupport::SpyExecutor.new(TestSupport.execution_result(model_present: false))).call('code' => 'x')
    assert_includes result[:content].first[:text], 'model_present: false'
  end
end
