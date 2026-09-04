# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Адаптер к SketchUp: единственное место, где исполнитель обращается к API приложения.
    class SketchupHost
      def active_model
        model = Sketchup.active_model
        model if model && model.valid?
      end

      def invalidate_view(model)
        view = model.active_view
        view.invalidate if view
      rescue StandardError
        nil
      end
    end

    ExecutionResult = Struct.new(
      :ok, :return_value, :stdout, :stderr, :error, :elapsed_ms, :truncated, :model_present,
      keyword_init: true
    )

    # Выполняет код агента на главном потоке SketchUp: одна операция undo на вызов,
    # захват stdout / stderr, структурированные ошибки, лимиты на объём вывода.
    class RubyExecutor
      Limits = Struct.new(:stream_bytes, :value_bytes, :backtrace_frames, keyword_init: true)
      DEFAULT_LIMITS = Limits.new(stream_bytes: 256 * 1024, value_bytes: 64 * 1024, backtrace_frames: 15).freeze
      EVAL_FILENAME = '(execute_ruby)'
      # SystemExit перехватываем, чтобы exit в коде агента не закрыл SketchUp.
      # NoMemoryError и SignalException намеренно пропускаем дальше.
      RESCUED = [StandardError, ScriptError, SystemStackError, SystemExit, SecurityError].freeze
      BUSY_MESSAGE = 'Executor is busy: a previous execute_ruby call has not finished ' \
                     '(it is probably blocked in a modal dialog)'
      TOPLEVEL_BINDING_SOURCE = -> { TOPLEVEL_BINDING }

      def initialize(host: SketchupHost.new, limits: DEFAULT_LIMITS, binding_source: TOPLEVEL_BINDING_SOURCE)
        @host = host
        @limits = limits
        @binding_source = binding_source
        @busy = false
      end

      def busy?
        @busy
      end

      def model_present?
        !@host.active_model.nil?
      end

      def execute(code, operation_name:, wrap_in_operation:)
        return busy_result if @busy

        @busy = true
        begin
          perform(code, operation_name, wrap_in_operation)
        ensure
          @busy = false
        end
      end

      private

      def perform(code, operation_name, wrap_in_operation)
        started_at = Clock.now
        model = @host.active_model
        wrap = wrap_in_operation && !model.nil?
        stdout = OutputCapture.new(@limits.stream_bytes)
        stderr = OutputCapture.new(@limits.stream_bytes)
        outcome = with_captured_streams(stdout, stderr) do
          run_in_operation(model, operation_name, wrap) { evaluate(code) }
        end
        build_result(outcome, stdout, stderr, model, started_at)
      end

      def evaluate(code)
        @binding_source.call.eval(code, EVAL_FILENAME, 1)
      end

      # Возвращает [:ok, значение] или [:error, исключение]; операция undo закрывается в любом случае.
      def run_in_operation(model, operation_name, wrap)
        model.start_operation(operation_name, true) if wrap
        value = yield
        if wrap
          model.commit_operation
          @host.invalidate_view(model)
        end
        [:ok, value]
      rescue *RESCUED => error
        abort_quietly(model) if wrap
        [:error, error]
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

      def build_result(outcome, stdout, stderr, model, started_at)
        status, payload = outcome
        return_value, value_truncated = status == :ok ? inspect_value(payload) : [nil, false]
        ExecutionResult.new(
          ok: status == :ok,
          return_value: return_value,
          stdout: stream_text(stdout),
          stderr: stream_text(stderr),
          error: status == :ok ? nil : describe_error(payload),
          elapsed_ms: ((Clock.now - started_at) * 1000).round(1),
          truncated: value_truncated || stdout.truncated? || stderr.truncated?,
          model_present: !model.nil?
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
        value.inspect
      rescue *RESCUED => error
        "#<#{value.class} (inspect failed: #{error.class}: #{error.message})>"
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

        error.message
      end

      # Кадры кода агента идут до первого кадра исполнителя; внутренние кадры клиенту не нужны.
      def visible_backtrace(error)
        frames = Array(error.backtrace)
        internal_start = frames.index { |frame| frame.start_with?(__FILE__) }
        visible = internal_start ? frames.first(internal_start) : frames
        visible = frames.first(3) if visible.empty?
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
          model_present: model_present?
        )
      end
    end
  end
end
