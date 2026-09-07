# frozen_string_literal: true

require 'set'

module SkRubyMcp
  module Runtime
    SessionResult = Struct.new(
      :ok, :state, :code, :message, :next, :already_open, :snapshot, :requested_path, :reverted,
      :locals_cleared, :saved_as, :copied, :copy_path, :saved, :temporary,
      :instead, :changed,
      keyword_init: true
    )

    # Политика одного документа. Долгие операции живут в @pending и двигаются
    # на следующих вызовах, без ожидания и без помпы run loop.
    class NotASkpFile < ArgumentError; end
    class NewerSketchupFile < ArgumentError; end

    class DocumentSession
      include DocumentPending
      include SavePolicy
      # OPEN_DEADLINE_S: когда бросаем незавершённое открытие.
      # IN_CALL_WAIT_S: сколько HTTP-ответ ждёт готовности, не блокируя тик.
      OPEN_DEADLINE_S = 30.0
      IN_CALL_WAIT_S = 15.0
      NEXT_WHEN_EMPTY = 'Call model_new for a blank document, or model_open with an absolute .skp path.'
      NEXT_WHEN_OPENING = 'Call model_status with wait_s=15 until state is active.'
      NEXT_WHEN_CREATING = 'The previous file is closed. Call model_status with wait_s=15. That status call attaches the blank. ' \
                           'Do not call model_new again. Do not call execute_ruby until state is active.'
      LOCALS_CLEARED_NEXT = 'previous locals, constants and methods are gone; anything you put on ::Object survives'

      def initialize(bridge:, locals_cleaner: nil)
        @bridge = bridge
        @locals_cleaner = locals_cleaner
        @pending = nil
        @last_failure = nil
        @named_paths = Set.new
        @locals_cleared_pending = false
        @temporary_paths = Set.new
        @tick = 0
        @last_focus_identity = nil
        @focus_changed_at = nil
        @timeout_requested = nil
        # Sticky leftover без фокуса (лишние окна): снимается, когда extras исчезли.
        @leftover_while_unfocused = false
        @leftover_focus_identity = nil
      end

      def pending?
        !@pending.nil?
      end

      def begin_tick
        @tick += 1
      end

      def empty_document_next
        NEXT_WHEN_EMPTY
      end

      def path_probe
        @bridge.path_probe
      end

      def ruby_refusal
        clear_count_unknown_if_focused
        if @pending && !focused_matches_pending?
          creating = @pending[:kind] == :create
          return {
            class: 'DocumentOpening',
            message: creating ? 'A blank document is still opening. Call model_status until state is active. Do not call model_new again.' : 'A document operation is still opening. Call model_status until state is active.',
            next: creating ? NEXT_WHEN_CREATING : NEXT_WHEN_OPENING,
            model_present: false
          }
        end
        refresh_sticky_failure
        return nil unless sticky_failure?

        {
          class: @last_failure.code,
          message: @last_failure.message,
          next: @last_failure.next,
          model_present: !opening_safe_snapshot.nil?
        }
      end

      def note_external_switch
        snap = @bridge.snapshot
        return nil if snap.nil?

        identity = focus_identity(snap)
        return nil if identity && identity == @last_focus_identity

        @focus_changed_at = Clock.now
        note_switch
        @last_focus_identity = identity
        nil
      end

      def status
        clear_count_unknown_if_focused
        timed_out = resolve_pending
        return decorate(timed_out) if timed_out
        return opening_status if @pending
        clear_timeout_if_focus_is_readable
        refresh_sticky_failure
        return decorate(@last_failure) if sticky_failure?

        snap = @bridge.snapshot
        if snap
          clear_failure
          decorate(
            outcome(
              ok: true,
              state: 'active',
              snapshot: snap,
              temporary: temporary_snap?(snap)
            )
          )
        else
          blocked = refuse_unfocused_documents
          return decorate(blocked) if blocked

          decorate(outcome(ok: true, state: 'no_document', next: NEXT_WHEN_EMPTY))
        end
      rescue StandardError => error
        decorate(failure('model_status_failed', "#{error.class}: #{error.message}"))
      end

      def open(path:, if_unsaved: nil)
        resolved = failed_pending_result
        return decorate(resolved) if resolved

        requested = validate_existing_skp(path)
        blocked = refuse_if_pending
        return decorate(blocked) if blocked

        snap = @bridge.snapshot
        if snap && !snap.untitled? && @bridge.paths_equal?(snap.path, requested)
          remember(requested)
          clear_failure
          return decorate(
            outcome(
              ok: true,
              state: 'active',
              already_open: true,
              changed: 'noop',
              snapshot: snap,
              requested_path: requested
            )
          )
        end

        if snap.nil?
          blocked = refuse_unfocused_documents
          return decorate(blocked) if blocked
        end

        previous = saved_path(snap)
        switched = switch_away(if_unsaved)
        return decorate(switched) unless switched.nil?

        begin
          queue_file_open(kind: :open, path: requested, previous_path: previous, changed: 'opened')
        rescue StandardError => error
          return decorate(restore_after_failed_dispatch('model_open_failed', error, previous))
        end
        decorate(finish_open_once)
      rescue NotASkpFile => error
        decorate(failure('not_a_skp_file', error.message))
      rescue NewerSketchupFile => error
        decorate(failure('newer_sketchup_file', error.message, next_step: error.message))
      rescue ArgumentError => error
        decorate(failure('invalid_model_path', error.message))
      rescue StandardError => error
        decorate(failure('model_open_failed', "#{error.class}: #{error.message}"))
      end

      def new_document(if_unsaved: nil)
        resolved = failed_pending_result
        return decorate(resolved) if resolved
        if @pending
          return decorate(
            failure(
              'open_in_progress',
              "Another document operation is in progress for #{pending_label}. Call model_status until it finishes."
            )
          )
        end

        snap = @bridge.snapshot
        if snap
          switched = switch_away(if_unsaved)
          return decorate(switched) unless switched.nil?

          if @bridge.current_model
            after = @bridge.snapshot
            if after && after.untitled? && !after.modified
              return decorate(start_create(saved_path(snap), consume_untitled: true))
            end

            return decorate(store_failure('leftover_document', leftover_message(focused: true), next_step: leftover_next(focused: true)))
          end

          return decorate(start_create(saved_path(snap)))
        end

        blocked = refuse_unfocused_documents
        return decorate(blocked) if blocked

        decorate(start_create(nil))
      rescue StandardError => error
        decorate(failure('model_new_failed', "#{error.class}: #{error.message}"))
      end

      def save(mode: 'in_place', path: nil, version: nil)
        resolved = failed_pending_result
        return decorate(resolved) if resolved
        blocked = refuse_if_pending
        return decorate(blocked) if blocked

        model = @bridge.current_model
        if model.nil?
          blocked = refuse_unfocused_documents
          return decorate(blocked) if blocked

          return decorate(failure('no_document', "No focused document. #{NEXT_WHEN_EMPTY}"))
        end

        chosen = (mode.nil? || mode.to_s.empty?) ? 'in_place' : mode.to_s
        unless %w[in_place save_as copy].include?(chosen)
          return decorate(
            failure(
              'unknown_arguments',
              'mode must be in_place, save_as or copy.',
              next_step: 'Call model_save with mode in_place, save_as or copy.'
            )
          )
        end

        target = empty_to_nil(path)
        chosen = effective_save_mode(chosen, target)
        if chosen == 'copy'
          unless target
            return decorate(
              failure(
                'path_required',
                'Saving a copy needs an absolute .skp path. The focused file stays where it is.',
                next_step: 'Call model_save with mode copy and an absolute .skp path.'
              )
            )
          end

          target = validate_save_skp(target)
          @bridge.save_copy(model, target, version: version)
          remember(target)
          clear_failure
          return decorate(outcome(ok: true, state: 'active', snapshot: @bridge.snapshot, copied: true, copy_path: target, changed: 'copied'))
        end

        if chosen == 'save_as'
          unless target
            return decorate(failure('path_required', 'save_as needs an absolute .skp path.'))
          end

          target = validate_save_skp(target)
          @bridge.save_as(model, target)
          remember(target)
          clear_failure
          return decorate(outcome(ok: true, state: 'active', snapshot: @bridge.snapshot, saved_as: true, changed: 'saved_as'))
        end

        if model.path.to_s.empty?
          return decorate(
            failure(
              'path_required',
              'This document has never been saved. Call model_save with an absolute .skp path.'
            )
          )
        end

        unless session_named?(model.path)
          return decorate(failure('unnamed_save', unnamed_save_message))
        end

        @bridge.save(model)
        clear_failure
        decorate(outcome(ok: true, state: 'active', snapshot: @bridge.snapshot, changed: 'saved'))
      rescue ArgumentError => error
        next_step = if error.message.match?(/copy|VERSION|SketchUp \d/i)
                      'Call model_save without version, or use mode save_as with a path.'
                    end
        decorate(failure('invalid_model_path', error.message, next_step: next_step))
      rescue StandardError => error
        decorate(failure('model_save_failed', "#{error.class}: #{error.message}"))
      end

      def close(if_unsaved: nil)
        resolved = failed_pending_result
        return decorate(resolved) if resolved
        blocked = refuse_if_pending
        return decorate(blocked) if blocked

        model = @bridge.current_model
        if model.nil?
          blocked = refuse_unfocused_documents
          return decorate(blocked) if blocked

          clear_failure
          return decorate(failure('no_document', "No focused document. #{NEXT_WHEN_EMPTY}"))
        end

        snap = @bridge.snapshot
        decision = unsaved_decision(snap, if_unsaved)
        return decorate(decision) if decision.is_a?(SessionResult)

        saved = false
        if decision == :save
          @bridge.save(model)
          saved = true
        end

        @bridge.close(model, true)
        note_switch
        clear_failure
        discard_unmodified_leftover_untitled
        leftover = @bridge.snapshot
        if leftover
          return decorate(
            outcome(
              ok: true,
              state: 'active',
              snapshot: leftover,
              saved: saved || nil,
              changed: 'closed',
              next: leftover_close_next(leftover)
            )
          )
        end

        decorate(outcome(ok: true, state: 'no_document', saved: saved || nil, changed: 'closed', next: NEXT_WHEN_EMPTY))
      rescue StandardError => error
        decorate(failure('model_close_failed', "#{error.class}: #{error.message}"))
      end

      def revert
        resolved = failed_pending_result
        return decorate(resolved) if resolved
        blocked = refuse_if_pending
        return decorate(blocked) if blocked

        model = @bridge.current_model
        if model.nil?
          blocked = refuse_unfocused_documents
          return decorate(blocked) if blocked

          return decorate(failure('no_document', "No focused document. #{NEXT_WHEN_EMPTY}"))
        end

        path = model.path.to_s
        if path.empty?
          return decorate(
            failure(
              'path_required',
              'Untitled documents cannot revert. Call model_save with a path, or model_close with if_unsaved=discard.',
              next_step: 'Call model_save with a path, or model_close with if_unsaved=discard.'
            )
          )
        end

        requested = @bridge.canonical(path)
        remember(requested)
        @bridge.close(model, true)
        note_switch
        begin
          queue_file_open(
            kind: :revert,
            path: requested,
            previous_path: requested,
            changed: 'reverted',
            reverted: true
          )
        rescue StandardError => error
          return decorate(restore_after_failed_dispatch('model_revert_failed', error, requested))
        end
        result = finish_open_once
        if result.ok && result.state == 'active'
          result.reverted = true
          result.changed = 'reverted'
        end
        decorate(result)
      rescue StandardError => error
        decorate(failure('model_revert_failed', "#{error.class}: #{error.message}"))
      end

      private

      def refuse_if_pending
        return nil unless @pending

        failure(
          'open_in_progress',
          "A document operation is in progress for #{pending_label}. Call model_status until state is active or failed."
        )
      end

      def defer_open_until_next_tick?
        @bridge.defer_open_until_next_tick?
      end

      def leftover_documents?
        extra_documents? || hidden_documents?
      end

      def extra_documents?
        count = document_count
        return false if count.nil?

        count > 1
      end

      def hidden_documents?
        count = document_count
        return false if count.nil?

        @bridge.snapshot.nil? && count.positive?
      end

      def document_count_unknown?
        document_count.nil?
      end

      def clear_count_unknown_if_focused
        return unless @last_failure && @last_failure.code == 'document_count_unknown'
        return unless @bridge.snapshot

        clear_failure
      end

      def refuse_unknown_count
        return nil unless document_count_unknown?

        store_failure(
          'document_count_unknown',
          'SketchUp document count is unknown. Call model_status. Do not call model_close to clear this.'
        )
      end

      def refuse_unfocused_documents
        unknown = refuse_unknown_count
        return unknown if unknown
        return nil unless leftover_documents?

        store_failure(
          'leftover_document',
          leftover_message(focused: false),
          next_step: leftover_next(focused: false),
          leftover_while_unfocused: true
        )
      end

      def leftover_message(focused:)
        if focused
          'A leftover document is still focused. Call model_status. Call model_close only if you want none, then model_new or model_open.'
        else
          'A leftover document is open but not focused. Close the extra SketchUp window yourself, then call model_status. Tools cannot close an unfocused window.'
        end
      end

      def leftover_next(focused:)
        if focused
          'Call model_status. Call model_close only if you want none, then model_new or model_open.'
        else
          'Close extra SketchUp windows yourself, then call model_status. Do not call model_close; nothing is focused.'
        end
      end


      def document_count
        return nil unless @bridge.respond_to?(:document_count)

        @bridge.document_count
      end


      def sticky_failure?
        return false unless @last_failure

        %w[leftover_document model_new_failed document_count_unknown model_open_timeout].include?(@last_failure.code)
      end

      # Успешный attach не возвращаем: вызывающий продолжает свою операцию.
      def failed_pending_result
        resolved = resolve_pending
        return nil if resolved.nil? || resolved.ok

        resolved
      end

      def clear_timeout_if_focus_is_readable
        return unless @last_failure && @last_failure.code == 'model_open_timeout'
        return if @pending

        if @bridge.current_model.nil?
          clear_failure
          return
        end

        snap = @bridge.snapshot
        return unless snap && @timeout_requested
        return unless @bridge.paths_equal?(snap.path, @timeout_requested)

        clear_failure
      end

      def refresh_sticky_failure
        return unless @last_failure

        case @last_failure.code
        when 'leftover_document'
          if !document_count_unknown? && !leftover_documents?
            clear_failure if @leftover_while_unfocused || @bridge.current_model.nil? || leftover_focus_replaced?
          end
        when 'document_count_unknown'
          clear_failure unless document_count_unknown?
        when 'model_new_failed'
          clear_failure
        end
      end




      def discard_unmodified_leftover_untitled
        leftover = @bridge.snapshot
        return unless leftover && leftover.untitled? && !leftover.modified

        model = @bridge.current_model
        return unless model

        @bridge.close(model, true)
      end

      def leftover_focus_replaced?
        return false if @leftover_focus_identity.nil?

        focus_identity(@bridge.snapshot) != @leftover_focus_identity
      end

      def leftover_document_focus(code, leftover_while_unfocused)
        return nil unless code == 'leftover_document'
        return nil if leftover_while_unfocused

        focus_identity(@bridge.snapshot)
      end

      def leftover_close_next(leftover)
        if leftover.untitled?
          'A leftover Untitled is focused. Call model_close with if_unsaved=discard if you want none.'
        else
          'A leftover file is focused. Call model_close with if_unsaved=discard if you want none.'
        end
      end

      def note_switch
        @locals_cleaner.call if @locals_cleaner
        @locals_cleared_pending = true
      end

      def decorate(result)
        return result if result.nil?

        apply_locals_cleared(result)
        if result.state == 'active'
          mark_focus(result.snapshot)
        elsif result.state == 'no_document'
          mark_focus(nil)
        end
        result
      end

      def mark_focus(snap)
        @last_focus_identity = focus_identity(snap)
      end

      def focus_identity(snap)
        return nil unless snap

        [snap.identity, snap.path]
      end

      def apply_locals_cleared(result)
        return unless @locals_cleared_pending
        return unless result.state == 'active' || result.state == 'no_document'

        result.locals_cleared = true
        @locals_cleared_pending = false
        if result.next.to_s.empty? && result.ok && result.state == 'active'
          result.next = LOCALS_CLEARED_NEXT
        end
      end

      def empty_to_nil(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def effective_save_mode(chosen, target)
        return 'save_as' if chosen == 'in_place' && target

        chosen
      end

      def outcome(**fields)
        SessionResult.new(**{ already_open: false }.merge(fields))
      end

      def failure(code, message, next_step: nil, instead: nil)
        SessionResult.new(
          ok: false,
          state: 'failed',
          code: code,
          message: message,
          next: next_step || hint_for(code),
          instead: instead,
          snapshot: opening_safe_snapshot
        )
      end

      def opening_safe_snapshot
        return nil if @pending && !focused_matches_pending?

        @bridge.snapshot
      end

      def store_failure(code, message, next_step: nil, leftover_while_unfocused: false, keep_pending: false)
        @pending = nil unless keep_pending
        @leftover_while_unfocused = leftover_while_unfocused
        @leftover_focus_identity = leftover_document_focus(code, leftover_while_unfocused)
        @last_failure = failure(code, message, next_step: next_step)
      end

      def clear_failure
        @last_failure = nil
        @timeout_requested = nil
        @leftover_while_unfocused = false
        @leftover_focus_identity = nil
      end

      def hint_for(code)
        case code
        when 'no_document' then NEXT_WHEN_EMPTY
        when 'model_new_failed'
          'Create failed. Call model_status. model_new is allowed now if nothing is opening.'
        when 'model_status_failed'
          'Call model_status again. Do not assume the last file is focused.'
        when 'unsaved_changes'
          'Call again with if_unsaved=save (only if this session opened or saved the file) or if_unsaved=discard.'
        when 'untitled_needs_path'
          'Call model_save with a path, or retry with if_unsaved=discard.'
        when 'path_required' then 'Call model_save with an absolute .skp path.'
        when 'unknown_arguments' then 'Pass only the documented arguments.'
        when 'open_in_progress', 'model_open_timeout' then 'Call model_status, then retry the document tool if state is failed.'
        when 'leftover_document' then 'Call model_status. Call model_close only if you want none, then model_new or model_open.'
        when 'document_count_unknown' then 'Call model_status. Do not call model_close to clear this.'
        when 'switch_failed' then 'Call model_status. The focused file is usually still there.'
        when 'not_a_skp_file' then 'Pass a real .skp file, not another format.'
        when 'newer_sketchup_file'
          'Open the file in the SketchUp that wrote it, or ask the architect for a copy saved for this host.'
        when 'invalid_model_path' then 'Pass an absolute .skp path. For model_open the file must exist. For model_save the directory must exist.'
        when 'unnamed_save' then 'Call model_save with mode save_as and an absolute .skp path.'
        when 'model_open_failed', 'model_save_failed', 'model_close_failed', 'model_switch_failed', 'model_revert_failed'
          'Call model_status. The focused file is usually still there. Do not call model_new unless status is no_document.'
        else NEXT_WHEN_EMPTY
        end
      end
    end
  end
end
