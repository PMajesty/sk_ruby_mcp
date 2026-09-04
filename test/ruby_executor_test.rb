# frozen_string_literal: true

require_relative 'test_helper'

class RubyExecutorTest < Minitest::Test
  RubyExecutor = SkRubyMcp::Runtime::RubyExecutor

  def setup
    @host = TestSupport::FakeHost.new
    @sandbox_binding = Object.new.instance_eval { binding }
    @executor = RubyExecutor.new(host: @host, binding_source: -> { @sandbox_binding })
  end

  def run_code(code, wrap: true, name: 'Test op', executor: @executor)
    executor.execute(code, operation_name: name, wrap_in_operation: wrap)
  end

  def test_returns_inspect_of_last_expression
    result = run_code('[1, 2].map { |n| n * 2 }')
    assert result.ok
    assert_equal '[2, 4]', result.return_value
    assert_nil result.error
    assert result.model_present
    assert_kind_of Float, result.elapsed_ms
  end

  def test_locals_persist_between_calls_with_the_same_binding
    run_code('answer = 41')
    assert_equal '42', run_code('answer + 1').return_value
  end

  def test_captures_stdout_and_stderr_and_restores_globals
    stdout_before = $stdout
    stderr_before = $stderr
    result = run_code('puts "hello"; warn "careful"; :done')
    assert_equal "hello\n", result.stdout
    assert_equal "careful\n", result.stderr
    assert_same stdout_before, $stdout
    assert_same stderr_before, $stderr
  end

  def test_wraps_call_in_one_undo_operation_with_ui_disabled
    run_code('1', name: 'Build wall')
    assert_equal [[:start, 'Build wall', true], [:commit]], @host.model.events
    assert_equal 1, @host.model.active_view.invalidations
  end

  def test_aborts_operation_and_reports_error_details
    result = run_code("x = 1\nraise ArgumentError, 'boom'")
    refute result.ok
    assert_nil result.return_value
    assert_equal [[:start, 'Test op', true], [:abort]], @host.model.events
    assert_equal 'ArgumentError', result.error[:class]
    assert_equal 'boom', result.error[:message]
    assert result.error[:backtrace].any? { |frame| frame.start_with?('(execute_ruby):2') }
    refute result.error[:backtrace].any? { |frame| frame.include?('ruby_executor.rb') }
  end

  def test_skips_operation_when_wrapping_is_disabled
    run_code('1', wrap: false)
    assert_empty @host.model.events
  end

  def test_runs_without_operation_when_no_model_is_open
    @host.model = nil
    result = run_code('2 + 2')
    assert result.ok
    refute result.model_present
  end

  def test_syntax_errors_are_reported_not_raised
    result = run_code('def broken(')
    refute result.ok
    assert_equal 'SyntaxError', result.error[:class]
    refute_empty result.error[:backtrace]
  end

  def test_exit_is_neutralised
    result = run_code('exit 3')
    refute result.ok
    assert_equal 'SystemExit', result.error[:class]
    assert_includes result.error[:message], 'ignored'
    assert_includes result.error[:message], '3'
  end

  def test_stack_overflow_is_reported
    result = run_code('def deep; deep; end; deep')
    refute result.ok
    assert_equal 'SystemStackError', result.error[:class]
  end

  def test_fatal_errors_propagate_and_state_is_restored
    stdout_before = $stdout
    assert_raises(NoMemoryError) { run_code("raise NoMemoryError, 'gone'") }
    assert_same stdout_before, $stdout
    refute @executor.busy?
    assert_equal [[:start, 'Test op', true]], @host.model.events
  end

  def test_reentrant_call_is_refused_while_busy
    $sk_ruby_mcp_test_executor = @executor
    result = run_code("$sk_ruby_mcp_test_executor.execute('1', operation_name: 'inner', wrap_in_operation: false)")
    assert result.ok
    assert_includes result.return_value, 'ExecutorBusy'
    refute @executor.busy?
  ensure
    $sk_ruby_mcp_test_executor = nil
  end

  def test_stdout_is_capped_with_a_marker
    limits = RubyExecutor::Limits.new(stream_bytes: 32, value_bytes: 1024, backtrace_frames: 5)
    executor = RubyExecutor.new(host: @host, limits: limits, binding_source: -> { @sandbox_binding })
    result = run_code('print "a" * 100; nil', executor: executor)
    assert result.truncated
    assert_equal 32, result.stdout.split("\n").first.bytesize
    assert_includes result.stdout, 'bytes dropped'
  end

  def test_return_value_is_capped
    limits = RubyExecutor::Limits.new(stream_bytes: 1024, value_bytes: 40, backtrace_frames: 5)
    executor = RubyExecutor.new(host: @host, limits: limits, binding_source: -> { @sandbox_binding })
    result = run_code('"b" * 500', executor: executor)
    assert result.truncated
    assert_includes result.return_value, '[truncated:'
  end

  def test_invalid_bytes_in_output_and_messages_become_valid_utf8
    result = run_code('print "\xFF".b; raise "bad \xFF".b')
    assert result.stdout.valid_encoding?
    assert result.error[:message].valid_encoding?
  end

  def test_inspect_failures_do_not_break_the_result
    result = run_code('o = Object.new; def o.inspect; raise "no inspect"; end; o')
    assert result.ok
    assert_includes result.return_value, 'inspect failed'
  end

  def test_runaway_ruby_is_interrupted_and_the_operation_aborted
    executor = RubyExecutor.new(host: @host, binding_source: -> { @sandbox_binding }, default_timeout_s: 0.2)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = run_code('begin; 200_000_000.times { |i| i }; rescue => e; :swallowed; end', executor: executor)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    refute result.ok
    assert_equal 'Timeout::Error', result.error[:class]
    assert_includes result.error[:message], 'exceeded 0.2 s'
    assert_operator elapsed, :<, 2.0
    assert_equal [[:start, 'Test op', true], [:abort]], @host.model.events
    refute result.error[:backtrace].any? { |frame| frame.include?('timeout.rb') }
  end

  def test_per_call_timeout_overrides_the_default_and_zero_disables_it
    executor = RubyExecutor.new(host: @host, binding_source: -> { @sandbox_binding }, default_timeout_s: 0.05)
    slow = 'sleep 0.15; :done'
    refute executor.execute(slow, operation_name: 'op', wrap_in_operation: false).ok
    assert executor.execute(slow, operation_name: 'op', wrap_in_operation: false, timeout_s: 1).ok
    assert executor.execute(slow, operation_name: 'op', wrap_in_operation: false, timeout_s: 0).ok
  end
end
