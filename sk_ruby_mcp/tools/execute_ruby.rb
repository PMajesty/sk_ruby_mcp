# frozen_string_literal: true

module SkRubyMcp
  module Tools
    # Единственный инструмент сервера: спецификация для tools/list и вызов исполнителя.
    class ExecuteRuby
      NAME = 'execute_ruby'
      TITLE = 'Execute Ruby in SketchUp'
      DEFAULT_OPERATION_NAME = 'MCP execute_ruby'
      MAX_OPERATION_NAME_LENGTH = 80

      DESCRIPTION = <<~TEXT.strip
        Evaluate Ruby code inside the running SketchUp session, on the SketchUp main thread, with the full
        SketchUp Ruby API (Sketchup, Geom, UI, Layout) available. Use it to inspect, create, modify and delete
        anything in the model.

        Behaviour:
        - Runs in the top-level binding like the Ruby Console: local variables persist between calls, methods and
          constants defined at top level stay defined for the session.
        - The value of the last expression is returned as return_value (inspect, capped at 64 KB); puts/print output
          is captured into stdout and warnings into stderr (256 KB each).
        - Failures return isError with error.class, error.message and a backtrace whose frames point at
          (execute_ruby):LINE in your code. Fix the code and call again.
        - By default the whole call is one undo step: model.start_operation(operation_name, true), then commit, or
          abort on error. Pass wrap_in_operation=false for read-only queries or when your code manages its own
          operations.
        - The SketchUp UI is blocked while the code runs and there is no server-side timeout: keep each call focused
          and split long jobs into several calls. Never open modal dialogs (UI.messagebox, UI.inputbox, UI.openpanel,
          UI.savepanel) and never call exit.

        SketchUp API essentials:
        - The internal length unit is inches; use 10.mm, 2.5.m, 3.feet to convert.
        - Sketchup.active_model may be nil when no document is open (macOS); the result reports model_present.
        - model.active_entities is where the user is working (inside an open group or component);
          model.entities is always the model root.
        - Bulk geometry: entities.build { |builder| ... } (SketchUp 2022+) or Geom::PolygonMesh with
          entities.fill_from_mesh; create geometry inside a new group to avoid merging with existing edges and faces.
        - Do not call view.refresh in loops; the server calls view.invalidate once after a wrapped call.
      TEXT

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
            description: 'Wrap the call in a single undo operation (default true). Set false for read-only ' \
                         'queries or when the code manages its own start_operation / commit_operation.'
          }
        },
        required: ['code'],
        additionalProperties: false
      }.freeze

      OUTPUT_SCHEMA = {
        type: 'object',
        properties: {
          ok: { type: 'boolean' },
          return_value: { type: %w[string null], description: 'inspect of the last expression, nil on error' },
          stdout: { type: 'string' },
          stderr: { type: 'string' },
          error: {
            type: %w[object null],
            properties: {
              class: { type: 'string' },
              message: { type: 'string' },
              backtrace: { type: 'array', items: { type: 'string' } }
            },
            required: %w[class message backtrace]
          },
          elapsed_ms: { type: 'number' },
          truncated: { type: 'boolean' },
          model_present: { type: 'boolean' }
        },
        required: %w[ok return_value stdout stderr error elapsed_ms truncated model_present]
      }.freeze

      ANNOTATIONS = {
        title: TITLE,
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      }.freeze

      SPEC = {
        name: NAME,
        title: TITLE,
        description: DESCRIPTION,
        inputSchema: INPUT_SCHEMA,
        outputSchema: OUTPUT_SCHEMA,
        annotations: ANNOTATIONS
      }.freeze

      def initialize(executor:, wrap_in_operation_by_default: true)
        @executor = executor
        @wrap_in_operation_by_default = wrap_in_operation_by_default
      end

      def name
        NAME
      end

      def spec
        SPEC
      end

      def call(arguments)
        arguments = {} unless arguments.is_a?(Hash)
        code = arguments['code']
        unless code.is_a?(String) && !code.strip.empty?
          return tool_result(invalid_arguments_result('`code` must be a non-empty string'))
        end

        result = @executor.execute(
          code,
          operation_name: operation_name(arguments),
          wrap_in_operation: wrap_in_operation?(arguments)
        )
        tool_result(result)
      end

      private

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
        {
          content: [{ type: 'text', text: render_text(result) }],
          structuredContent: result.to_h,
          isError: !result.ok
        }
      end

      def render_text(result)
        lines = ["ok: #{result.ok}"]
        lines << "return_value: #{result.return_value}" if result.ok
        lines.concat(error_lines(result.error)) if result.error
        lines << "stdout:\n#{result.stdout}" unless result.stdout.empty?
        lines << "stderr:\n#{result.stderr}" unless result.stderr.empty?
        lines << 'model_present: false (no open document; the code ran without an undo operation)' unless result.model_present
        lines << 'truncated: true' if result.truncated
        lines << "elapsed_ms: #{result.elapsed_ms}"
        lines.join("\n")
      end

      def error_lines(error)
        lines = ["error: #{error[:class]}: #{error[:message]}"]
        return lines if error[:backtrace].empty?

        lines << 'backtrace:'
        error[:backtrace].each { |frame| lines << "  #{frame}" }
        lines
      end
    end
  end
end
