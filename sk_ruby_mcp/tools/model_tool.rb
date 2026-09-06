# frozen_string_literal: true

module SkRubyMcp
  module Tools
    # Общий каркас именованного инструмента над сфокусированной моделью: проверка документа,
    # разбор аргументов, одна операция undo. Наследник задаёт NAME, TITLE, DESCRIPTION,
    # INPUT_SCHEMA, ALLOWED_KEYS, ANNOTATIONS, output_schema, parse_arguments и run_on_model.
    class ModelTool
      POLLS_WHILE_BUSY = false

      def initialize(session:, attach:)
        raise ArgumentError, 'session is required' if session.nil?
        raise ArgumentError, 'attach is required' if attach.nil?

        @session = session
        @attach = attach
      end

      def name
        self.class::NAME
      end

      def polls_while_busy?
        false
      end

      def spec
        {
          name: self.class::NAME,
          title: self.class::TITLE,
          description: self.class::DESCRIPTION,
          inputSchema: self.class::INPUT_SCHEMA,
          outputSchema: output_schema,
          annotations: self.class::ANNOTATIONS
        }
      end

      def call(arguments)
        arguments = {} unless arguments.is_a?(Hash)
        unknown = ArgumentGuard.unknown_message(arguments, self.class::ALLOWED_KEYS)
        if unknown
          return ToolReply.call(
            ok: false,
            error: 'unknown_arguments',
            message: unknown,
            retry: false,
            next: 'Pass only the documented arguments.'
          )
        end

        if (refusal = @session.ruby_refusal)
          return ToolReply.call(
            ok: false,
            error: refusal[:class],
            message: refusal[:message],
            retry: true,
            instead: 'model_status',
            next: refusal[:next]
          )
        end

        status = @session.status
        unless status.ok && status.state == 'active'
          return ToolReply.call(
            ok: false,
            error: status.code || 'no_document',
            message: status.message || 'No focused document. Call model_new or model_open.',
            retry: true,
            instead: 'model_status',
            next: status.next || @session.empty_document_next
          )
        end

        model = @attach.current_model
        if model.nil? || (model.respond_to?(:valid?) && !model.valid?)
          return ToolReply.call(
            ok: false,
            error: 'no_document',
            message: 'No focused document. Call model_new or model_open.',
            retry: true,
            instead: 'model_status',
            next: @session.empty_document_next
          )
        end

        parsed = parse_arguments(arguments)
        return parsed if parsed.is_a?(Hash) && parsed[:content]

        payload = run_on_model(model, parsed)
        ToolReply.call(payload)
      rescue ArgumentError => error
        ToolReply.call(
          ok: false,
          error: 'unknown_arguments',
          message: error.message,
          retry: false,
          next: 'Pass only the documented arguments.'
        )
      rescue StandardError, ScriptError => error
        ToolReply.call(
          ok: false,
          error: 'ruby_error',
          message: "#{error.class}: #{error.message}",
          retry: true,
          instead: 'model_status'
        )
      end

      private

      def invalid(message)
        ToolReply.call(
          ok: false,
          error: 'unknown_arguments',
          message: message,
          retry: false,
          next: 'Pass only the documented arguments.'
        )
      end

      def vec3(value, name)
        return nil if value.nil?
        unless value.is_a?(Array) && value.size == 3 && value.all? { |item| item.is_a?(Numeric) }
          raise ArgumentError, "#{name} must be [x, y, z] numbers in metres"
        end

        value.map(&:to_f)
      end

      def number(value, name)
        return nil if value.nil?
        raise ArgumentError, "#{name} must be a number" unless value.is_a?(Numeric)

        value.to_f
      end

      def integer(value, name)
        return nil if value.nil?
        unless value.is_a?(Integer) || (value.is_a?(Numeric) && value == value.to_i)
          raise ArgumentError, "#{name} must be an integer"
        end

        value.to_i
      end

      def text(value)
        value.nil? ? nil : value.to_s
      end

      def boolean(value, name)
        return nil if value.nil?
        return value if value == true || value == false
        if value.is_a?(String)
          down = value.strip.downcase
          return true if %w[true yes 1].include?(down)
          return false if %w[false no 0].include?(down)
        end
        if value.is_a?(Numeric)
          return true if value == 1
          return false if value == 0
        end

        raise ArgumentError, "#{name} must be a boolean"
      end

      def with_operation(model, label)
        committed = false
        model.start_operation(label, true) if model.respond_to?(:start_operation)
        result = yield
        if model.respond_to?(:commit_operation)
          model.commit_operation
          committed = true
        end
        view = model.active_view if model.respond_to?(:active_view)
        view.invalidate if view.respond_to?(:invalidate)
        result
      ensure
        if !committed && model.respond_to?(:abort_operation)
          begin
            model.abort_operation
          rescue StandardError, ScriptError
            nil
          end
        end
      end
    end
  end
end
