# frozen_string_literal: true

# Инструменты документа: статус, открытие, бланк, сохранение, закрытие, откат.

module SkRubyMcp
  module Tools
    class SessionTool
      def initialize(session:)
        @session = session
      end

      def name
        self.class::NAME
      end

      POLLS_WHILE_BUSY = false

      def polls_while_busy?
        self.class::POLLS_WHILE_BUSY
      end

      def spec
        {
          name: self.class::NAME,
          title: self.class::TITLE,
          description: self.class::DESCRIPTION,
          inputSchema: self.class::INPUT_SCHEMA,
          outputSchema: DOCUMENT_OUTPUT_SCHEMA,
          annotations: self.class::ANNOTATIONS
        }
      end

      def call(arguments)
        arguments = {} unless arguments.is_a?(Hash)
        unknown = ArgumentGuard.unknown_message(arguments, self.class::INPUT_SCHEMA[:properties].keys)
        if unknown
          return ToolReply.call(
            ok: false,
            error: 'unknown_arguments',
            message: unknown,
            retry: false,
            next: 'Pass only the documented arguments.'
          )
        end

        maybe_defer(run(arguments))
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

      def render(result)
        snap = result.snapshot
        path = snap && Runtime::PathIdentity.display(snap.path)
        requested = Runtime::PathIdentity.display(result.requested_path)
        ToolReply.call(
          ok: result.ok,
          state: result.state,
          changed: result.changed || changed_from(result),
          path: path,
          path_requested: path_requested(path, requested),
          title: snap && (snap.title.to_s.empty? ? 'Untitled' : snap.title),
          modified: snap && snap.modified,
          temporary: result.temporary ? true : nil,
          copy_path: Runtime::PathIdentity.display(result.copy_path),
          scope_reset: result.locals_cleared ? true : nil,
          model: model_block(snap),
          error: result.ok ? nil : result.code,
          message: result.ok ? nil : result.message,
          retry: result.ok ? nil : true,
          instead: result.instead,
          next: result.next
        )
      end

      def changed_from(result)
        return 'noop' if result.already_open
        return 'reverted' if result.reverted
        return 'copied' if result.copied
        return 'saved_as' if result.saved_as
        return 'saved' if result.saved
        return 'none' if result.ok && result.state == 'active'

        nil
      end

      def path_requested(path, requested)
        return nil if requested.nil? || requested == path

        requested
      end

      def model_block(snap)
        return nil unless snap

        {
          'faces' => snap.faces,
          'bounds_m' => snap.bounds_m,
          'units' => snap.units,
          'root_entities' => snap.root_entities,
          'objects' => snap.objects,
          'objects_truncated' => snap.objects_truncated,
          'tags' => snap.tags,
          'materials' => snap.materials,
          'selection' => snap.selection,
          'edit_context' => snap.edit_context
        }
      end

      def invalid_if_unsaved(value)
        return nil if value.nil? || %w[save discard].include?(value.to_s)

        ToolReply.call(
          ok: false,
          error: 'unknown_arguments',
          message: 'if_unsaved must be save or discard.',
          retry: false,
          next: 'Pass if_unsaved=save or if_unsaved=discard, or omit it.'
        )
      end

      def wait_s_from(arguments)
        raw = arguments['wait_s']
        return 0 if raw.nil?
        if raw.is_a?(Integer)
          value = raw
        elsif raw.is_a?(Numeric) && raw == raw.to_i
          value = raw.to_i
        else
          return :invalid
        end
        return :invalid if value.negative?

        value > 15 ? 15 : value
      end

      def maybe_defer(result)
        return result if result.is_a?(Runtime::Deferred)
        return result unless result.is_a?(Hash)
        return result unless opening_result?(result)
        return result if self.class::POLLS_WHILE_BUSY

        defer_until_ready(result, Runtime::DocumentSession::IN_CALL_WAIT_S)
      end

      def defer_until_ready(opening, deadline_s)
        Runtime::Deferred.new(
          deadline_s: deadline_s,
          poll: lambda do
            latest = render(@session.status)
            opening_result?(latest) ? nil : latest
          end,
          timeout_result: -> { opening }
        )
      end

      def opening_result?(result)
        payload = result[:structuredContent] || result
        payload.is_a?(Hash) && (payload['state'] == 'opening' || payload[:state] == 'opening')
      end
    end

    class ModelStatus < SessionTool
      NAME = 'model_status'
      TITLE = 'Focused document'
      POLLS_WHILE_BUSY = true
      DESCRIPTION = <<~TEXT.strip
        Report the focused SketchUp document and a cheap picture of the model. Call this first, after any reply with state opening, and after SketchUp restarts. States: active (draw with execute_ruby), no_document (call model_new or model_open), opening (a file is still loading; call this again with wait_s=15). This call may finish a pending open or attach a pending blank; it never closes or saves anything. path is the real path on disk (null for Untitled); path_requested is your spelling when it differed. model lists faces across all nesting, bounds in metres, units, and up to 20 top-level groups and components with bounds; nested detail needs execute_ruby.
        Arguments: wait_s (optional integer 0..15, default 0): while state is opening, wait up to this long for it to finish before replying.
      TEXT
      INPUT_SCHEMA = {
        type: 'object',
        properties: {
          wait_s: {
            type: 'integer',
            minimum: 0,
            maximum: 15,
            description: 'While state is opening, wait up to this many seconds (default 0).'
          }
        },
        additionalProperties: false
      }.freeze
      ANNOTATIONS = {
        title: TITLE,
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      }.freeze

      def run(arguments)
        wait_s = wait_s_from(arguments)
        if wait_s == :invalid
          return ToolReply.call(
            ok: false,
            error: 'invalid_wait_s',
            message: 'wait_s must be an integer from 0 to 15.',
            retry: false,
            next: 'Pass wait_s as an integer from 0 to 15, or omit it.'
          )
        end

        result = render(@session.status)
        return result unless wait_s.positive? && opening_result?(result)

        defer_until_ready(result, wait_s)
      end
    end

    class ModelOpen < SessionTool
      NAME = 'model_open'
      TITLE = 'Open a SketchUp model'
      DESCRIPTION = <<~TEXT.strip
        Open an existing .skp file and make it the focused document. This is also the switch: if another document is focused, it is closed first. Waits up to 15 seconds for the file to load and returns the focused document; if loading is slower, returns state opening (then call model_status with wait_s=15). Opening the path that is already focused is a no-op with changed noop. Do not use Sketchup.open_file in execute_ruby.
        Arguments: path (required): absolute path to an existing .skp file, not a file name. if_unsaved (optional, "save" or "discard"): required when the focused document has unsaved changes. save works only for a file this session opened or saved; a dirty Untitled needs model_save with a path first, or discard.
      TEXT
      INPUT_SCHEMA = {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Absolute path to an existing .skp file.' },
          if_unsaved: { type: 'string', enum: %w[save discard], description: 'Required when the focused document has unsaved changes.' }
        },
        required: ['path'],
        additionalProperties: false
      }.freeze
      ANNOTATIONS = {
        title: TITLE,
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false
      }.freeze

      def run(arguments)
        path = arguments['path']
        unless path.is_a?(String) && !path.strip.empty?
          return ToolReply.call(
            ok: false,
            error: 'path_required',
            message: 'path must be a non-empty string.',
            retry: false,
            next: 'Call model_open with an absolute .skp path.'
          )
        end

        if_unsaved = arguments['if_unsaved']
        invalid = invalid_if_unsaved(if_unsaved)
        return invalid if invalid

        render(@session.open(path: path, if_unsaved: if_unsaved))
      end
    end

    class ModelNew < SessionTool
      NAME = 'model_new'
      TITLE = 'New SketchUp document'
      DESCRIPTION = <<~TEXT.strip
        Create a blank focused document for new work. If another document is focused, it is closed first, and the blank is attached within the same call (up to 15 seconds), otherwise state opening is returned (then call model_status with wait_s=15). While state is opening, a second model_new is refused with open_in_progress and the pending blank keeps loading; poll model_status instead. After state active, draw with execute_ruby. If the reply has temporary true, the file lives in a scratch location: call model_save with mode save_as and the path the architect wants before treating it as finished.
        Arguments: if_unsaved (optional, "save" or "discard"): required when the focused document has unsaved changes; same rules as model_open.
      TEXT
      INPUT_SCHEMA = {
        type: 'object',
        properties: {
          if_unsaved: { type: 'string', enum: %w[save discard], description: 'Required when the focused document has unsaved changes.' }
        },
        additionalProperties: false
      }.freeze
      ANNOTATIONS = {
        title: TITLE,
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: false
      }.freeze

      def run(arguments)
        if_unsaved = arguments['if_unsaved']
        invalid = invalid_if_unsaved(if_unsaved)
        return invalid if invalid

        render(@session.new_document(if_unsaved: if_unsaved))
      end
    end

    class ModelSave < SessionTool
      NAME = 'model_save'
      TITLE = 'Save the SketchUp document'
      DESCRIPTION = <<~TEXT.strip
        Save the focused document. mode in_place (default) writes the focused file to its own path and is allowed only for a file this session opened or saved; otherwise use save_as. mode save_as writes to path and the model lives there from now on; the original file on disk is left as it was. mode copy writes path as a copy and the focused model stays where it is. Saving twice is safe. Does not close, revert or switch.
        Arguments: mode (optional: "in_place", "save_as", "copy"; default "in_place"). path (required for save_as and copy; absolute .skp path). version (optional integer year, copy only): write the copy for an older SketchUp version when the host supports it.
      TEXT
      INPUT_SCHEMA = {
        type: 'object',
        properties: {
          mode: { type: 'string', enum: %w[in_place save_as copy], description: 'in_place, save_as or copy (default in_place).' },
          path: { type: 'string', description: 'Absolute .skp path. Required for save_as and copy.' },
          version: { type: 'integer', description: 'SketchUp year for a copy, when the host supports it.' }
        },
        additionalProperties: false
      }.freeze
      ANNOTATIONS = {
        title: TITLE,
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false
      }.freeze

      def run(arguments)
        mode = arguments.key?('mode') ? arguments['mode'] : 'in_place'
        render(@session.save(mode: mode, path: arguments['path'], version: arguments['version']))
      end
    end

    class ModelClose < SessionTool
      NAME = 'model_close'
      TITLE = 'Close the SketchUp document'
      DESCRIPTION = <<~TEXT.strip
        Close the focused document. Afterwards state is no_document, or active if SketchUp keeps another window focused (the reply says which). To reload the last saved version instead, use model_revert.
        Arguments: if_unsaved (optional, "save" or "discard"): required when the document has unsaved changes. save works only for a file this session opened or saved; a dirty Untitled needs model_save with a path first, or discard.
      TEXT
      INPUT_SCHEMA = {
        type: 'object',
        properties: {
          if_unsaved: { type: 'string', enum: %w[save discard], description: 'Required when the document has unsaved changes.' }
        },
        additionalProperties: false
      }.freeze
      ANNOTATIONS = {
        title: TITLE,
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: false
      }.freeze

      def run(arguments)
        if_unsaved = arguments['if_unsaved']
        invalid = invalid_if_unsaved(if_unsaved)
        return invalid if invalid

        render(@session.close(if_unsaved: if_unsaved))
      end
    end

    class ModelRevert < SessionTool
      NAME = 'model_revert'
      TITLE = 'Revert the SketchUp document'
      DESCRIPTION = <<~TEXT.strip
        Discard all unsaved changes in the focused document and reload it from its last saved file. Untitled cannot revert: use model_save with a path, or model_close with if_unsaved=discard. Waits up to 15 seconds for the reload; may return state opening (then call model_status with wait_s=15). No arguments.
      TEXT
      INPUT_SCHEMA = {
        type: 'object',
        properties: {},
        additionalProperties: false
      }.freeze
      ANNOTATIONS = {
        title: TITLE,
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: false
      }.freeze

      def run(_arguments)
        render(@session.revert)
      end
    end
  end
end
