# frozen_string_literal: true

require 'timeout'

module SkRubyMcp
  module Runtime
    class RefusedCall < StandardError; end

    # Адаптер к SketchUp: единственное место, где исполнитель обращается к API приложения.
    class SketchupHost
      def active_model
        @attach.current_model
      end

      def invalidate_view(model)
        view = model.active_view
        view.invalidate if view
      rescue StandardError
        nil
      end

      def initialize(attach: SketchupAttachBridge.new)
        @attach = attach
      end
    end

    ExecutionResult = Struct.new(
      :ok, :return_value, :stdout, :stderr, :error, :elapsed_ms, :truncated, :model_present,
      :model_path, :model_title, :timed_out, :edit_context, :scope_reset, :undo_step,
      keyword_init: true
    )

    # На время вызова подменяет убийцы процесса; в ensure возвращает оригиналы.
    class ProcessGuards
      def initialize
        @restorers = []
      end

      def install
        shadow_instance(Kernel, :exit!)
        shadow_singleton(Kernel, :exit!)
        shadow_instance(Kernel, :exec)
        shadow_singleton(Kernel, :exec)
        shadow_instance(Kernel, :system)
        shadow_singleton(Kernel, :system)
        shadow_instance(Kernel, :spawn)
        shadow_singleton(Kernel, :spawn)
        shadow_instance(Kernel, :`)
        shadow_singleton(Kernel, :`)
        shadow_singleton(Process, :exit!)
        shadow_singleton(Process, :exec)
        shadow_singleton(Process, :kill)
        shadow_singleton(Process, :spawn)
        shadow_singleton(IO, :popen)
        shadow_kernel_open
        shadow_singleton(Thread, :new)
        shadow_singleton(Thread, :start)
        shadow_singleton(Thread, :fork) if Thread.respond_to?(:fork)
        shadow_instance(Kernel, :fork)
        shadow_singleton(Kernel, :fork)
        shadow_singleton(Process, :fork)
        if defined?(Sketchup)
          shadow_singleton(Sketchup, :quit) if Sketchup.respond_to?(:quit)
          shadow_singleton(Sketchup, :open_file) if Sketchup.respond_to?(:open_file)
          shadow_singleton(Sketchup, :file_new) if Sketchup.respond_to?(:file_new)
        end
      end

      def restore
        @restorers.reverse_each do |restorer|
          restorer.call
        rescue StandardError
          nil
        end
        @restorers.clear
      end

      private

      def shadow_instance(mod, name)
        return unless mod.method_defined?(name) || mod.private_method_defined?(name)

        original = mod.instance_method(name)
        was_private = mod.private_method_defined?(name)
        was_protected = mod.protected_method_defined?(name)
        mod.define_method(name) do |*_args|
          raise RefusedCall, "#{name} is refused"
        end
        mod.send(:private, name) if was_private
        mod.send(:protected, name) if was_protected
        @restorers << lambda do
          mod.define_method(name, original)
          mod.send(:private, name) if was_private
          mod.send(:protected, name) if was_protected
        end
      end

      def shadow_kernel_open
        return unless Kernel.method_defined?(:open) || Kernel.private_method_defined?(:open)

        original = Kernel.instance_method(:open)
        was_private = Kernel.private_method_defined?(:open)
        Kernel.define_method(:open) do |*args, &block|
          first = args[0]
          path = if first.respond_to?(:to_path)
                   first.to_path
                 elsif first.respond_to?(:to_str)
                   first.to_str
                 else
                   first
                 end
          if path.is_a?(String) && path.start_with?('|')
            raise RefusedCall, 'open is refused'
          end

          original.bind(self).call(*args, &block)
        end
        Kernel.send(:private, :open) if was_private
        @restorers << lambda do
          Kernel.define_method(:open, original)
          Kernel.send(:private, :open) if was_private
        end
      end

      def shadow_singleton(mod, name)
        return unless mod.respond_to?(name, true)

        original = mod.method(name)
        mod.define_singleton_method(name) do |*_args|
          raise RefusedCall, "#{mod}.#{name} is refused"
        end
        @restorers << lambda do
          mod.define_singleton_method(name, original)
        end
      end
    end

    # Выполняет код агента на главном потоке SketchUp: одна операция undo на вызов,
    # захват stdout / stderr, структурированные ошибки, лимиты на объём вывода.
    class RubyExecutor
      Limits = Struct.new(:stream_bytes, :value_bytes, :backtrace_frames, keyword_init: true)
      DEFAULT_LIMITS = Limits.new(stream_bytes: 64 * 1024, value_bytes: 32 * 1024, backtrace_frames: 15).freeze
      EVAL_FILENAME = '(execute_ruby)'
      RESCUED = [StandardError, ScriptError, SystemStackError, SystemExit, SecurityError].freeze
      BUSY_MESSAGE = 'Executor is busy: a previous execute_ruby call has not finished. It may be blocked in a modal dialog.'
      DEFAULT_TIMEOUT_S = 30.0
      MAX_TIMEOUT_S = 3600.0
      PLUGIN_BACKTRACE = %r{sk_ruby_mcp|/timeout\.rb:|vbo-sk-agent|/Plugins/sk_ruby}
      NO_MODEL_MESSAGE = 'No focused SketchUp document. Call model_status, then model_new for a blank file ' \
                         'or model_open with an absolute .skp path. Do not use ObjectSpace or AppObserver models: ' \
                         'geometry on those objects crashes SketchUp 2022.'
      SUMMARISE_AFTER = 200
      SKETCHUP_COLLECTIONS = %w[Sketchup::Entities Sketchup::Selection Sketchup::DefinitionList].freeze

      def initialize(host: SketchupHost.new, limits: DEFAULT_LIMITS, binding_source: nil,
                     default_timeout_s: DEFAULT_TIMEOUT_S)
        @host = host
        @limits = limits
        @binding_source = binding_source
        @default_timeout_s = default_timeout_s
        @busy = false
        @eval_binding = nil
        @scope_just_reset = false
      end

      def busy?
        @busy
      end

      def model_present?
        !@host.active_model.nil?
      end

      def reset_document_scope
        @eval_binding = mint_scope
        @scope_just_reset = true
        nil
      end

      def execute(code, operation_name:, wrap_in_operation:, timeout_s: nil)
        return busy_result if @busy

        @busy = true
        begin
          perform(code, operation_name, wrap_in_operation, normalize_timeout(timeout_s))
        ensure
          @busy = false
        end
      end

      private

      def mint_scope
        Object.new.instance_eval('binding')
      end

      def current_binding
        @eval_binding ||= if @binding_source
                            @binding_source.call
                          else
                            mint_scope
                          end
      end

      def normalize_timeout(timeout_s)
        seconds = timeout_s.nil? ? @default_timeout_s : Float(timeout_s)
        seconds = @default_timeout_s unless seconds.positive?
        seconds.clamp(0.001, MAX_TIMEOUT_S)
      rescue ArgumentError, TypeError
        @default_timeout_s
      end

      def perform(code, operation_name, wrap_in_operation, timeout_s)
        started_at = Clock.now
        model = @host.active_model
        return no_model_result(started_at) if model.nil?

        wrap = wrap_in_operation
        stdout = OutputCapture.new(@limits.stream_bytes)
        stderr = OutputCapture.new(@limits.stream_bytes)
        outcome = with_captured_streams(stdout, stderr) do
          run_in_operation(model, operation_name, wrap) { evaluate(code, timeout_s) }
        end
        build_result(outcome, stdout, stderr, started_at, timeout_s, wrap)
      end

      def evaluate(code, timeout_s)
        guards = ProcessGuards.new
        run = lambda do |*_ignored|
          guards.install
          current_binding.eval(code, EVAL_FILENAME, 1)
        ensure
          guards.restore
        end
        return run.call unless timeout_s.positive?

        message = "execution exceeded #{timeout_s} s"
        Timeout.timeout(timeout_s, nil, message, &run)
      end

      def run_in_operation(model, operation_name, wrap)
        committed = false
        model.start_operation(operation_name, true) if wrap
        value = yield
        if wrap
          model.commit_operation
          committed = true
          @host.invalidate_view(model)
        end
        [:ok, value]
      rescue *RESCUED => error
        [:error, error]
      ensure
        abort_quietly(model) if wrap && !committed
      end

      def abort_quietly(model)
        model.abort_operation
      rescue *RESCUED
        nil
      end

      def with_captured_streams(stdout, stderr)
        previous_stdout = $stdout
        previous_stderr = $stderr
        $stdout = stdout
        $stderr = stderr
        yield
      ensure
        $stdout = previous_stdout
        $stderr = previous_stderr
      end

      def build_result(outcome, stdout, stderr, started_at, timeout_s, wrap)
        status, payload = outcome
        elapsed_ms = ((Clock.now - started_at) * 1000).round(1)
        timed_out = nil
        undo_step = if wrap
                      status == :ok ? 'committed' : 'aborted'
                    else
                      'none'
                    end
        if timeout_error?(payload)
          timed_out = timeout_payload(payload, elapsed_ms, timeout_s)
          payload = timeout_error_with_message(payload, timed_out)
        end
        return_value, value_truncated = status == :ok ? inspect_value(payload) : [nil, false]
        scope_reset = @scope_just_reset
        @scope_just_reset = false
        ExecutionResult.new(
          ok: status == :ok,
          return_value: return_value,
          stdout: stream_text(stdout),
          stderr: stream_text(stderr),
          error: status == :ok ? nil : describe_error(payload),
          elapsed_ms: elapsed_ms,
          truncated: value_truncated || stdout.truncated? || stderr.truncated?,
          model_present: model_present?,
          timed_out: timed_out,
          edit_context: current_edit_context,
          scope_reset: scope_reset,
          undo_step: undo_step,
          **identity_fields
        )
      end

      def timeout_error?(error)
        error.is_a?(Exception) && error.is_a?(Timeout::Error)
      end

      def timeout_payload(error, elapsed_ms, limit_s)
        elapsed_s = elapsed_ms / 1000.0
        interrupted = elapsed_s <= (limit_s + 1.0)
        {
          limit_s: limit_s,
          elapsed_s: elapsed_s.round(3),
          interrupted: interrupted
        }
      end

      def timeout_error_with_message(error, timed_out)
        message = if timed_out[:interrupted]
                    "interrupted at #{timed_out[:limit_s]} s; the undo step was aborted"
                  else
                    "ran #{timed_out[:elapsed_s]} s, past the #{timed_out[:limit_s]} s limit; " \
                    'a SketchUp call could not be interrupted; the undo step was aborted and nothing from this call remains'
                  end
        rewritten = Timeout::Error.new(message)
        rewritten.set_backtrace(error.backtrace)
        rewritten
      end

      def current_edit_context
        model = @host.active_model
        return nil unless model

        ModelSnapshotFactory.edit_context(model)
      end

      def identity_fields
        model = @host.active_model
        return { model_path: nil, model_title: nil } unless model

        path = model.respond_to?(:path) ? model.path.to_s : ''
        title = model.respond_to?(:title) ? model.title.to_s : ''
        {
          model_path: PathIdentity.display(path),
          model_title: title.empty? ? nil : title
        }
      end

      def no_model_result(started_at)
        ExecutionResult.new(
          ok: false,
          return_value: nil,
          stdout: '',
          stderr: '',
          error: { class: 'NoActiveModel', message: NO_MODEL_MESSAGE, backtrace: [] },
          elapsed_ms: ((Clock.now - started_at) * 1000).round(1),
          truncated: false,
          model_present: false,
          model_path: nil,
          model_title: nil,
          timed_out: nil,
          edit_context: nil,
          scope_reset: false,
          undo_step: 'none'
        )
      end

      def stream_text(capture)
        text = capture.string
        return text unless capture.truncated?

        "#{text}\n... [truncated: #{capture.dropped_bytes} bytes dropped] ..."
      end

      def inspect_value(value)
        TextTrimmer.truncate(safe_inspect(value), @limits.value_bytes)
      end

      def safe_inspect(value)
        summary = summarise(value)
        return summary if summary

        value.inspect
      rescue *RESCUED => error
        "#<#{value.class} (inspect failed: #{error.class}: #{error.message})>"
      end

      def summarise(value)
        class_name = value.class.name.to_s
        if SKETCHUP_COLLECTIONS.include?(class_name)
          return format_summary(class_name, collection_length(value), preview_items(value))
        end

        return nil unless value.is_a?(Enumerable) && !value.is_a?(String)

        count = collection_length(value)
        return nil if count.nil? || count <= SUMMARISE_AFTER

        format_summary(class_name.empty? ? value.class.to_s : class_name, count, preview_items(value))
      end

      def format_summary(class_name, count, first)
        "#<#{class_name} count=#{count} first=[#{first.join(', ')}]>"
      end

      def collection_length(value)
        return value.length if value.respond_to?(:length)
        return value.size if value.respond_to?(:size)

        nil
      rescue StandardError
        nil
      end

      def preview_items(value)
        first = []
        value.each do |item|
          first << item.inspect
          break if first.size == 3
        end
        first
      rescue StandardError
        []
      end

      def describe_error(error)
        {
          class: error.class.name,
          message: TextTrimmer.utf8(error_message(error)),
          backtrace: visible_backtrace(error)
        }
      end

      def error_message(error)
        return "exit was called with status #{error.status} and ignored" if error.is_a?(SystemExit)
        return error.message if error.is_a?(RefusedCall)

        error.message
      end

      def visible_backtrace(error)
        frames = Array(error.backtrace)
        visible = frames.reject { |frame| frame.match?(PLUGIN_BACKTRACE) || frame.start_with?(__FILE__) }
        visible = frames.select { |frame| frame.include?('(execute_ruby)') } if visible.empty?
        visible.first(@limits.backtrace_frames).map { |frame| TextTrimmer.utf8(frame) }
      end

      def busy_result
        ExecutionResult.new(
          ok: false,
          return_value: nil,
          stdout: '',
          stderr: '',
          error: { class: 'ExecutorBusy', message: BUSY_MESSAGE, backtrace: [] },
          elapsed_ms: 0.0,
          truncated: false,
          model_present: model_present?,
          timed_out: nil,
          edit_context: current_edit_context,
          scope_reset: false,
          undo_step: 'none'
        )
      end
    end
  end
end
