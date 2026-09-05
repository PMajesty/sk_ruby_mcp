# frozen_string_literal: true

module SkRubyMcp
  module Tools
    # Единственный инструмент моделирования: eval на главном потоке SketchUp.
    class ExecuteRuby
      NAME = 'execute_ruby'
      TITLE = 'Execute Ruby in SketchUp'
      DEFAULT_OPERATION_NAME = 'MCP execute_ruby'
      MAX_OPERATION_NAME_LENGTH = 80

      INPUT_SCHEMA = {
        type: 'object',
        properties: {
          code: {
            type: 'string',
            description: 'Ruby source to evaluate in SketchUp. The value of the last expression is returned.'
          },
          operation_name: {
            type: 'string',
            description: "Label of the undo step (default \"#{DEFAULT_OPERATION_NAME}\")."
          },
          wrap_in_operation: {
            type: 'boolean',
            description: 'Wrap the call in a single undo operation (default true). Set false for read-only queries.'
          },
          timeout_s: {
            type: 'number',
            minimum: 0,
            description: 'Server-side limit in seconds for this call (default 30). 0 uses the default. ' \
                         'A long single SketchUp API call cannot be interrupted; the reply says so.'
          }
        },
        required: ['code'],
        additionalProperties: false
      }.freeze

      ALLOWED_ARGUMENT_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze

      ANNOTATIONS = {
        title: TITLE,
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: false
      }.freeze

      def initialize(executor:, session:, wrap_in_operation_by_default: true, host_info: nil)
        raise ArgumentError, 'session is required' if session.nil?

        @executor = executor
        @session = session
        @wrap_in_operation_by_default = wrap_in_operation_by_default
        @host_info = host_info
      end

      def name
        NAME
      end

      def polls_while_busy?
        false
      end

      def spec
        {
          name: NAME,
          title: TITLE,
          description: built_description,
          inputSchema: INPUT_SCHEMA,
          outputSchema: EXECUTE_OUTPUT_SCHEMA,
          annotations: ANNOTATIONS
        }
      end

      def call(arguments)
        arguments = {} unless arguments.is_a?(Hash)
        unknown = ArgumentGuard.unknown_message(arguments, ALLOWED_ARGUMENT_KEYS)
        if unknown
          return tool_result(invalid_arguments_result(unknown))
        end

        code = arguments['code']
        unless code.is_a?(String) && !code.strip.empty?
          return tool_result(invalid_arguments_result('code must be a non-empty string'))
        end

        if (refusal = @session.ruby_refusal)
          return ToolReply.call(
            ok: false,
            error: refusal[:class],
            message: refusal[:message],
            retry: true,
            instead: refusal[:next].to_s.include?('model_status') ? 'model_status' : nil,
            next: refusal[:next]
          )
        end

        result = @executor.execute(
          code,
          operation_name: operation_name(arguments),
          wrap_in_operation: wrap_in_operation?(arguments),
          timeout_s: timeout_s(arguments)
        )
        tool_result(result)
      end

      private

      def built_description
        info = resolved_host_info
        ruby_note = if info[:ruby].to_s < '3.0'
                      ' Ruby 2.7: no Hash#except, no endless methods, no Array#intersect?, pattern matching is experimental.'
                    else
                      ''
                    end
        <<~TEXT.strip
          Evaluate Ruby in the focused SketchUp document. Use it for all modelling: massing, windows, copies, floors, materials, tags, purge, Sketchup.undo. Never open, create, save, close or revert documents here; the model_* tools do that. Host: SketchUp #{info[:sketchup]}, Ruby #{info[:ruby]}, #{info[:platform]}.#{ruby_note}
          Each call is one undo step: aborted whole on any exception, committed otherwise. Do not call start_operation or commit_operation inside; a nested operation commits ours. Set wrap_in_operation=false only for read-only queries. The last expression comes back as return_value (inspect, capped). Locals, constants and helper methods persist across calls on the same document and are gone after a document switch. Never open dialogs (UI.messagebox, inputbox, openpanel) and never call exit, exit!, abort or Sketchup.quit; they are refused. Each call has a time limit (default 30 s, timeout_s to change); a SketchUp call that runs past it cannot be interrupted and blocks every other tool until it returns, so punch one opening or do one heavy API call per execute_ruby.
          SketchUp facts: lengths are inches unless written like 10.m, 250.mm or "3m".to_l. add_face returns nil or raises ArgumentError on duplicate, collinear or non-planar points; check before pushpull. pushpull follows the front normal; a face drawn on the ground faces down, so check face.normal (reverse! if needed) or the extrusion goes the wrong way. Draw inside a new group (entities.add_group then group.entities) so faces do not merge with existing geometry. Copies of a group or component share one definition: call make_unique on a copy before editing it alone. Do not multiply a Geom::Vector3d by a Length; scale with a number (vector * 2). Draw in model.active_entities; edit_context in the reply says where that is. Z is up.
          Arguments: code (required). operation_name (optional, default "MCP execute_ruby", max 80). wrap_in_operation (optional, default true). timeout_s (optional number, default 30).
        TEXT
      end

      def resolved_host_info
        @host_info || {
          sketchup: sketchup_version,
          ruby: RUBY_VERSION,
          platform: host_platform
        }
      end

      def sketchup_version
        return Sketchup.version.to_s if defined?(Sketchup) && Sketchup.respond_to?(:version)

        'unknown'
      end

      def host_platform
        return 'mac' if defined?(Sketchup) && Sketchup.respond_to?(:platform) && Sketchup.platform == :platform_osx
        return 'windows' if defined?(Sketchup) && Sketchup.respond_to?(:platform) && Sketchup.platform == :platform_win

        RUBY_PLATFORM
      end

      def timeout_s(arguments)
        value = arguments['timeout_s']
        value.is_a?(Numeric) && value >= 0 ? value.to_f : nil
      end

      def operation_name(arguments)
        name = arguments['operation_name'].to_s.strip
        name.empty? ? DEFAULT_OPERATION_NAME : name[0, MAX_OPERATION_NAME_LENGTH]
      end

      def wrap_in_operation?(arguments)
        return @wrap_in_operation_by_default unless arguments.key?('wrap_in_operation')

        arguments['wrap_in_operation'] == true
      end

      def invalid_arguments_result(message)
        Runtime::ExecutionResult.new(
          ok: false,
          return_value: nil,
          stdout: '',
          stderr: '',
          error: { class: 'ArgumentError', message: message, backtrace: [] },
          elapsed_ms: 0.0,
          truncated: false,
          model_present: @executor.model_present?
        )
      end

      def tool_result(result)
        payload = {
          ok: result.ok,
          return_value: result.return_value,
          stdout: result.stdout,
          stderr: result.stderr,
          truncated: result.truncated,
          elapsed_ms: result.elapsed_ms,
          undo_step: result.undo_step,
          edit_context: result.edit_context,
          path: result.model_path,
          title: result.model_title,
          scope_reset: result.scope_reset ? true : nil,
          timed_out: result.timed_out
        }
        unless result.ok
          payload[:error] = error_code(result)
          payload[:message] = result.error && result.error[:message]
          payload[:retry] = true
          payload[:ruby] = result.error
          recovery = failure_recovery(result)
          payload[:instead] = recovery[:instead]
          payload[:next] = recovery[:next]
        end
        if result.scope_reset
          payload[:next] = 'previous locals, constants and methods are gone; anything you put on ::Object survives'
        end
        ToolReply.call(payload)
      end

      def error_code(result)
        klass = result.error && result.error[:class].to_s
        return 'no_document' if klass == 'NoActiveModel'
        return 'timeout' if klass.include?('Timeout')
        return 'refused_call' if klass.include?('RefusedCall')
        return 'unknown_arguments' if klass == 'ArgumentError'

        'ruby_error'
      end

      def failure_recovery(result)
        case error_code(result)
        when 'no_document'
          { instead: nil, next: @session.empty_document_next }
        when 'timeout'
          { instead: nil, next: 'Punch one opening or one heavy API call per execute_ruby, then retry.' }
        when 'unknown_arguments'
          { instead: nil, next: 'Pass only the documented arguments.' }
        else
          { instead: nil, next: nil }
        end
      end
    end
  end
end
