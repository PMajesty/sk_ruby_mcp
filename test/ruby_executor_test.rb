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
    assert_equal 'committed', result.undo_step
  end

  def test_read_only_call_does_not_claim_an_undo_step
    result = run_code('1 + 1', wrap: false)
    assert result.ok
    assert_equal 'none', result.undo_step
    assert_empty @host.model.events
  end

  def test_locals_persist_between_calls_with_the_same_binding
    run_code('answer = 41')
    assert_equal '42', run_code('answer + 1').return_value
  end

  def test_reset_document_scope_drops_locals_constants_and_helpers
    executor = RubyExecutor.new(host: @host)
    run_code('answer = 41; FOO = 7; def helper; 1; end; class ScopeBox; end', executor: executor)
    executor.reset_document_scope
    local = run_code('answer', executor: executor)
    refute local.ok
    assert_equal 'NameError', local.error[:class]
    constant = run_code('FOO', executor: executor)
    refute constant.ok
    helper = run_code('helper', executor: executor)
    refute helper.ok
    klass = run_code('ScopeBox', executor: executor)
    refute klass.ok
    Object.const_set(:SurvivesReset, 1) unless Object.const_defined?(:SurvivesReset)
    surviving = run_code('::Object::SurvivesReset', executor: executor)
    assert surviving.ok
    assert_equal '1', surviving.return_value
  ensure
    Object.send(:remove_const, :SurvivesReset) if Object.const_defined?(:SurvivesReset)
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

  def test_fails_closed_when_no_model_is_open
    @host.model = nil
    result = run_code('2 + 2')
    refute result.ok
    assert_equal 'NoActiveModel', result.error[:class]
    refute result.model_present
  end

  def test_model_present_is_read_after_eval
    $sk_ruby_mcp_test_host = @host
    result = run_code(
      '$sk_ruby_mcp_test_host.model = nil; 1',
      wrap: false
    )
    assert result.ok
    refute result.model_present
  ensure
    $sk_ruby_mcp_test_host = nil
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
    assert_equal [[:start, 'Test op', true], [:abort]], @host.model.events
  end

  def test_exit_bang_and_exec_and_quit_are_refused_and_shadows_are_gone
    original_exit = Kernel.instance_method(:exit!)
    original_exec = Kernel.instance_method(:exec)
    original_kernel_exec = Kernel.method(:exec)
    original_kernel_exit = Kernel.method(:exit!)
    original_process = Process.method(:exit!)
    original_process_exec = Process.method(:exec)
    original_process_kill = Process.method(:kill)
    result = run_code('exit!')
    refute result.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', result.error[:class]
    assert_includes result.error[:message], 'exit!'
    assert_equal original_exit, Kernel.instance_method(:exit!)
    assert_equal original_exec, Kernel.instance_method(:exec)
    assert_equal original_process, Process.method(:exit!)

    exec_result = run_code('exec("/no/such/skmcp-exec")')
    refute exec_result.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', exec_result.error[:class]

    process_result = run_code('Process.exit!')
    refute process_result.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', process_result.error[:class]

    process_exec = run_code('Process.exec("/no/such/skmcp-exec")')
    refute process_exec.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', process_exec.error[:class]
    assert_equal original_process_exec, Process.method(:exec)

    kernel_exec = run_code('Kernel.exec("/no/such/skmcp-exec")')
    refute kernel_exec.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', kernel_exec.error[:class]
    assert_equal original_kernel_exec, Kernel.method(:exec)

    kernel_exit = run_code('Kernel.exit!(99)')
    refute kernel_exit.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', kernel_exit.error[:class]
    assert_equal original_kernel_exit, Kernel.method(:exit!)

    process_kill = run_code('Process.kill("TERM", Process.pid)')
    refute process_kill.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', process_kill.error[:class]
    assert_equal original_process_kill, Process.method(:kill)

    original_system = Kernel.instance_method(:system)
    original_spawn = Kernel.instance_method(:spawn)
    original_backtick = Kernel.instance_method(:`)
    original_popen = IO.method(:popen)
    original_open = Kernel.instance_method(:open)
    system_result = run_code('system("true")')
    refute system_result.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', system_result.error[:class]
    spawn_result = run_code('spawn("true")')
    refute spawn_result.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', spawn_result.error[:class]
    backtick_result = run_code('`true`')
    refute backtick_result.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', backtick_result.error[:class]
    popen_result = run_code('IO.popen("true")')
    refute popen_result.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', popen_result.error[:class]
    pipe_open = run_code('open("|true")')
    refute pipe_open.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', pipe_open.error[:class]
    pathname_pipe = run_code("require 'pathname'; open(Pathname.new('|true'))")
    refute pathname_pipe.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', pathname_pipe.error[:class]
    thread_result = run_code('Thread.new { 1 }')
    refute thread_result.ok
    assert_equal 'SkRubyMcp::Runtime::RefusedCall', thread_result.error[:class]
    assert_equal original_system, Kernel.instance_method(:system)
    assert_equal original_spawn, Kernel.instance_method(:spawn)
    assert_equal original_backtick, Kernel.instance_method(:`)
    assert_equal original_popen, IO.method(:popen)
    assert_equal original_open, Kernel.instance_method(:open)

    sketchup = Module.new do
      def self.quit; :quit; end
      def self.open_file(*); :opened; end
      def self.file_new; :new; end
    end
    Object.const_set(:Sketchup, sketchup) unless defined?(Sketchup)
    begin
      original_quit = Sketchup.method(:quit)
      original_open_file = Sketchup.method(:open_file)
      original_file_new = Sketchup.method(:file_new)
      quit_result = run_code('Sketchup.quit')
      refute quit_result.ok
      assert_equal 'SkRubyMcp::Runtime::RefusedCall', quit_result.error[:class]
      open_file = run_code('Sketchup.open_file("/tmp/x.skp")')
      refute open_file.ok
      file_new = run_code('Sketchup.file_new')
      refute file_new.ok
      assert_equal original_quit, Sketchup.method(:quit)
      assert_equal original_open_file, Sketchup.method(:open_file)
      assert_equal original_file_new, Sketchup.method(:file_new)
    ensure
      Object.send(:remove_const, :Sketchup) if Object.const_defined?(:Sketchup) && Sketchup == sketchup
    end
  end

  def test_large_enumerable_is_summarised
    result = run_code('(1..100_000).to_a')
    assert result.ok
    assert result.return_value.bytesize < 1024
    assert_includes result.return_value, 'count=100000'
  end

  def test_reply_carries_edit_context
    result = run_code('1')
    assert_equal 'root', result.edit_context
  end

  def test_timeout_past_the_limit_uses_honest_wording
    calls = 0
    SkRubyMcp::Clock.define_singleton_method(:now) do
      calls += 1
      calls == 1 ? 100.0 : 105.5
    end
    executor = RubyExecutor.new(host: @host, binding_source: -> { @sandbox_binding }, default_timeout_s: 0.2)
    result = executor.execute(
      'raise Timeout::Error, "execution exceeded 0.2 s"',
      operation_name: 'op',
      wrap_in_operation: true
    )
    refute result.ok
    assert_includes result.error[:message], 'past the 0.2 s limit'
    assert_includes result.error[:message], 'could not be interrupted'
    refute result.timed_out[:interrupted]
    assert_equal 0.2, result.timed_out[:limit_s]
  ensure
    SkRubyMcp::Clock.define_singleton_method(:now) { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
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
    assert_includes result.error[:message], 'interrupted at 0.2 s'
    assert_operator elapsed, :<, 2.0
    assert_equal [[:start, 'Test op', true], [:abort]], @host.model.events
    refute result.error[:backtrace].any? { |frame| frame.include?('timeout.rb') }
  end

  def test_per_call_timeout_overrides_the_default_and_zero_uses_the_default
    executor = RubyExecutor.new(host: @host, binding_source: -> { @sandbox_binding }, default_timeout_s: 0.05)
    slow = 'sleep 0.15; :done'
    refute executor.execute(slow, operation_name: 'op', wrap_in_operation: false).ok
    assert executor.execute(slow, operation_name: 'op', wrap_in_operation: false, timeout_s: 1).ok
    refute executor.execute(slow, operation_name: 'op', wrap_in_operation: false, timeout_s: 0).ok
  end
end
