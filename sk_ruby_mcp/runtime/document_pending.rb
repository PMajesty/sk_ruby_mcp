# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Открытия, создание бланка, восстановление и таймаут @pending.
    # Методы живут на DocumentSession: тик только двигает состояние.
    module DocumentPending
      private

      def resolve_pending
        return nil unless @pending

        if focused_matches_pending?
          return accept_pending_focus
        end

        if Clock.now - @pending[:started_at] > self.class::OPEN_DEADLINE_S
          return timeout_pending
        end

        if @pending[:kind] == :create
          advanced = advance_create
          return advanced unless advanced.nil?
        end

        nil
      end

      def start_create(previous_path, consume_untitled: false)
        @pending = {
          kind: :create,
          path: nil,
          started_at: Clock.now,
          previous_path: previous_path,
          created_on_tick: @tick,
          changed: 'created',
          file_new_attempted: consume_untitled,
          close_template: consume_untitled
        }
        opening_status
      end

      def advance_create
        return nil if @pending[:created_on_tick] && @tick <= @pending[:created_on_tick]
        return nil if @pending[:mutated_on_tick] == @tick

        unless @pending[:file_new_attempted]
          unknown = refuse_unknown_count
          return unknown if unknown
          if @bridge.snapshot || leftover_documents?
            return store_failure(
              'leftover_document',
              leftover_message(focused: !@bridge.snapshot.nil?),
              next_step: leftover_next(focused: !@bridge.snapshot.nil?)
            )
          end

          @bridge.create_new
          @pending[:file_new_attempted] = true
          @pending[:mutated_on_tick] = @tick
          snap = @bridge.snapshot
          return accept_blank(snap) if created_blank?(snap)
          if snap && snap.untitled? && !temporary_snap?(snap)
            if extra_documents?
              return store_failure(
                'leftover_document',
                leftover_message(focused: true),
                next_step: leftover_next(focused: true)
              )
            end

            @pending[:close_template] = true
            return nil
          end
          if snap
            return store_failure(
              'leftover_document',
              'Focus landed on an existing file instead of a blank document. Call model_close, then model_new.',
              next_step: 'Call model_close with if_unsaved=discard if you want none, then model_new.'
            )
          end

          return nil
        end

        if @pending[:close_template] && !@pending[:template_closed]
          model = @bridge.current_model
          if model
            @bridge.close(model, true)
            note_switch
          end
          @pending[:template_closed] = true
          @pending[:mutated_on_tick] = @tick
          return nil
        end

        return nil if @pending[:blank_dispatched]

        dest = @bridge.dispatch_blank
        unless dest
          return store_failure(
            'model_new_failed',
            'Could not attach a blank document. Call model_status, then model_new again.'
          )
        end

        @pending[:blank_dispatched] = true
        @pending[:mutated_on_tick] = @tick
        remember_temporary(dest)
        promote_create_to_temp_open(dest)
        return accept_pending_focus if focused_matches_pending?

        nil
      end

      def promote_create_to_temp_open(dest)
        @pending = {
          kind: :open,
          path: dest,
          started_at: @pending[:started_at],
          previous_path: @pending[:previous_path],
          temporary: true,
          changed: @pending[:changed] || 'created'
        }
      end

      def finish_open_once
        return accept_pending_focus if focused_matches_pending?

        opening_status
      end

      def accept_pending_focus
        snap = @bridge.snapshot
        requested = @pending[:path]
        temporary = @pending[:temporary]
        attached_temporary = temporary || temporary_snap?(snap)
        changed = @pending[:changed]
        reverted = @pending[:reverted]
        remember(requested) if requested && !attached_temporary
        @pending = nil
        clear_failure
        outcome(
          ok: true,
          state: 'active',
          already_open: false,
          snapshot: snap,
          requested_path: requested,
          temporary: attached_temporary,
          changed: changed,
          reverted: reverted
        )
      end

      def accept_blank(snap)
        @pending = nil
        clear_failure
        temporary = temporary_snap?(snap)
        next_step = if temporary
                      'This blank is a temporary file. Call model_save with an absolute .skp path.'
                    end
        outcome(ok: true, state: 'active', snapshot: snap, temporary: temporary, next: next_step, changed: 'created')
      end

      def timeout_pending
        requested = @pending[:path]
        previous = @pending[:previous_path]
        kind = @pending[:kind]
        @timeout_requested = requested
        @pending = nil
        focused = @bridge.current_model
        snap = @bridge.snapshot
        if focused && (snap.nil? || snap.modified)
          detail = if snap.nil?
                     'A leftover document is focused but its snapshot could not be read. Call model_status.'
                   else
                     'A leftover document with unsaved changes is still focused. Call model_save or model_close with if_unsaved=discard.'
                   end
          return store_failure(
            'model_open_timeout',
            "Timed out waiting for #{requested || 'a blank document'} to become the focused document. #{detail}",
            next_step: snap.nil? ? 'Call model_status. Do not retry the timed-out open yet.' : 'Call model_save with a path, or model_close with if_unsaved=discard. Do not retry the timed-out open yet.'
          )
        end
        if focused && snap && !snap.modified && kind == :create && snap.untitled?
          return store_failure(
            'model_open_timeout',
            'Timed out waiting for a blank document. An unmodified Untitled is still focused. Call model_status.',
            next_step: 'Call model_status. The Untitled is still focused. Do not retry the timed-out new yet.'
          )
        end
        if focused
          @bridge.close(focused, true)
          note_switch
        end
        if previous && @bridge.file?(previous)
          return begin_restore(
            previous,
            'model_open_timeout',
            "Timed out waiting for #{requested || 'a blank document'} to become the focused document. " \
            'The previous file is being reopened. Call model_status.'
          )
        end

        message = if kind == :create
                    'Timed out waiting for a blank document. Nothing is focused. Call model_new or model_open.'
                  else
                    "Timed out waiting for #{requested} to become the focused document. " \
                    'Nothing is focused. Call model_open or model_new.'
                  end
        store_failure('model_open_timeout', message, next_step: message)
      end

      def opening_status
        requested = @pending && @pending[:path]
        creating = @pending && @pending[:kind] == :create
        snap = focused_matches_pending? ? @bridge.snapshot : nil
        outcome(
          ok: true,
          state: 'opening',
          requested_path: requested,
          snapshot: snap,
          temporary: @pending && @pending[:temporary],
          next: creating ? self.class::NEXT_WHEN_CREATING : self.class::NEXT_WHEN_OPENING
        )
      end

      def focused_matches_pending?
        return false unless @pending

        snap = @bridge.snapshot
        return false unless snap

        case @pending[:kind]
        when :open, :restore
          !snap.untitled? && @pending[:path] && @bridge.paths_equal?(snap.path, @pending[:path])
        when :create
          created_blank?(snap)
        else
          false
        end
      end

      def created_blank?(snap)
        return false unless snap && @pending
        if temporary_snap?(snap)
          return @pending[:file_new_attempted] == true || @pending[:temporary] == true
        end
        return false unless empty_untitled?(snap)
        return false unless @pending[:file_new_attempted]
        return false if document_count_unknown?

        !extra_documents?
      end

      def empty_untitled?(snap)
        return false unless snap && snap.untitled?

        faces = snap.faces
        roots = snap.root_entities
        objects = snap.objects
        (faces.nil? || faces.zero?) && (roots.nil? || roots.zero?) && (objects.nil? || objects.empty?)
      end

      def begin_restore(previous, code, message)
        @bridge.open_path(previous)
        @pending = { kind: :restore, path: previous, started_at: Clock.now, previous_path: nil }
        store_failure(code, message, next_step: 'Call model_status until the previous file is focused.')
      rescue StandardError => error
        @pending = nil
        store_failure(
          code,
          "#{message} Could not reopen the previous file: #{error.class}: #{error.message}",
          next_step: 'Call model_status. The previous file may still be on disk.'
        )
      end

      def restore_after_failed_dispatch(code, error, previous)
        if previous && @bridge.file?(previous)
          return begin_restore(
            previous,
            code,
            "#{error.class}: #{error.message}. The previous file is being reopened. Call model_status."
          )
        end

        @pending = nil
        failure(code, "#{error.class}: #{error.message}")
      end

      def pending_label
        @pending[:path] || 'a blank document'
      end
    end
  end
end
