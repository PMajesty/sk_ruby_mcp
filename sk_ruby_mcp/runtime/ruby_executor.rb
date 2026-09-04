# frozen_string_literal: true

require 'timeout'

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
      DEFAULT_LIMITS = Limits.new(stream_bytes: 64 * 1024, value_bytes: 32 * 1024, backtrace_frames: 15).freeze
      EVAL_FILENAME = '(execute_ruby)'
      # SystemExit перехватываем, чтобы exit в коде агента не закрыл SketchUp.
      # NoMemoryError и SignalException намеренно пропускаем дальше.
      RESCUED = [StandardError, ScriptError, SystemStackError, SystemExit, SecurityError].freeze
      BUSY_MESSAGE = 'Executor is busy: a previous execute_ruby call has not finished ' \
                     '(it is probably blocked in a modal dialog)'
      TOPLEVEL_BINDING_SOURCE = -> { TOPLEVEL_BINDING }
      # Ниже клиентских лимитов Cursor и Codex (60 с), чтобы сервер успел откатить операцию и ответить.
      DEFAULT_TIMEOUT_S = 50.0
      MAX_TIMEOUT_S = 3600.0
      TIMEOUT_LIBRARY_FRAME = '/timeout.rb:'

      def initialize(host: SketchupHost.new, limits: DEFAULT_LIMITS, binding_source: TOPLEVEL_BINDING_SOURCE,
                     default_timeout_s: DEFAULT_TIMEOUT_S)
        @host = host
        @limits = limits
        @binding_source = binding_source
        @default_timeout_s = default_timeout_s
        @busy = false
      end

      def busy?
        @busy
      end

      def model_present?
        !@host.active_model.nil?
      end

      # timeout_s: nil берёт значение по умолчанию, 0 отключает ограничение.
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

      def normalize_timeout(timeout_s)
        seconds = timeout_s.nil? ? @default_timeout_s : timeout_s
        Float(seconds).clamp(0.0, MAX_TIMEOUT_S)
      rescue ArgumentError, TypeError
        @default_timeout_s
      end

      def perform(code, operation_name, wrap_in_operation, timeout_s)
        started_at = Clock.now
        model = @host.active_model
        wrap = wrap_in_operation && !model.nil?
        stdout = OutputCapture.new(@limits.stream_bytes)
        stderr = OutputCapture.new(@limits.stream_bytes)
        outcome = with_captured_streams(stdout, stderr) do
          run_in_operation(model, operation_name, wrap) { evaluate(code, timeout_s) }
        end
        build_result(outcome, stdout, stderr, model, started_at)
      end

      # Timeout прерывает только Ruby-код: один длинный вызов API SketchUp доработает до конца,
      # после чего исключение будет поднято. Внутри блока используется служебное исключение
      # Timeout, которое не перехватывается rescue StandardError в коде агента.
      def evaluate(code, timeout_s)
        return @binding_source.call.eval(code, EVAL_FILENAME, 1) unless timeout_s.positive?

        message = "execution exceeded #{timeout_s} s and was interrupted; split the work into smaller calls"
        Timeout.timeout(timeout_s, nil, message) { @binding_source.call.eval(code, EVAL_FILENAME, 1) }
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
        frames = Array(error.backtrace).reject { |frame| frame.include?(TIMEOUT_LIBRARY_FRAME) }
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
