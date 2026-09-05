# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Имена файлов сессии и правило if_unsaved при уходе с документа.
    module SavePolicy
      private

      def switch_away(if_unsaved)
        model = @bridge.current_model
        return nil if model.nil?

        snap = @bridge.snapshot
        decision = unsaved_decision(snap, if_unsaved)
        return decision if decision.is_a?(SessionResult)

        @bridge.save(model) if decision == :save
        @bridge.close(model, true)
        note_switch
        nil
      rescue StandardError => error
        @pending = nil
        failure('switch_failed', "#{error.class}: #{error.message}")
      end

      def unsaved_decision(snap, if_unsaved)
        if snap.nil? && @bridge.current_model
          return failure(
            'leftover_document',
            'A leftover document is focused but its snapshot could not be read. Call model_status.',
            next_step: 'Call model_status. Do not close or switch until the snapshot can be read.'
          )
        end

        return :clean unless snap && snap.modified

        title = snap.title.to_s.empty? ? 'Untitled' : snap.title
        if if_unsaved.nil? || if_unsaved.to_s.empty?
          next_step = if snap.untitled?
                        'Call model_save with a path, or retry with if_unsaved=discard.'
                      else
                        'Call again with if_unsaved=save (only if this session opened or saved the file) or if_unsaved=discard.'
                      end
          return failure(
            'unsaved_changes',
            "#{title} has unsaved changes.",
            next_step: next_step,
            instead: snap.untitled? ? 'model_save' : nil
          )
        end

        action = if_unsaved.to_s
        unless %w[save discard].include?(action)
          return failure(
            'unsaved_changes',
            "#{title} has unsaved changes.",
            next_step: 'Call again with if_unsaved=save or if_unsaved=discard.'
          )
        end
        return :discard if action == 'discard'

        if snap.untitled?
          return failure(
            'untitled_needs_path',
            'Untitled needs a path before it can be saved.',
            next_step: 'Call model_save with a path, or retry with if_unsaved=discard.',
            instead: 'model_save'
          )
        end
        unless session_named?(snap.path)
          return failure('unnamed_save', unnamed_save_message)
        end

        :save
      end

      def temporary_snap?(snap)
        return false unless snap
        return true if session_created_new?(snap.path)

        canonical = @bridge.canonical(snap.path)
        canonical && @temporary_paths.any? { |path| @bridge.paths_equal?(path, canonical) }
      end

      def saved_path(snap)
        return nil unless snap && !snap.untitled?

        @bridge.canonical(snap.path)
      end

      def remember(path)
        canonical = @bridge.canonical(path)
        @named_paths << canonical if canonical
      end

      def session_named?(path)
        canonical = @bridge.canonical(path)
        return false unless canonical

        @named_paths.any? { |named| @bridge.paths_equal?(named, canonical) }
      end

      def remember_temporary(path)
        canonical = @bridge.canonical(path)
        @temporary_paths << canonical if canonical
      end

      def unnamed_save_message
        if temporary_snap?(@bridge.snapshot)
          'This is a temporary document this session created. Call model_save with an absolute .skp path.'
        else
          'This file was not named in this session. Call model_save with its path if the architect asked to keep it.'
        end
      end

      def unnamed_save_message_for_close
        "#{unnamed_save_message} Or model_close with if_unsaved=discard."
      end

      def validate_existing_skp(path)
        raise ArgumentError, 'path must be an absolute .skp file' unless path.is_a?(String) && !path.strip.empty?

        cleaned = path.strip
        reject_remote_or_nonskp!(cleaned)
        unless absolute_path?(cleaned)
          raise ArgumentError, 'path must be absolute, not a file name. Example: /Users/me/project/house.skp'
        end
        unless @bridge.file?(cleaned)
          raise ArgumentError, "file does not exist: #{cleaned}"
        end

        header = SkpHeader.parse(cleaned)
        raise NotASkpFile, 'path is not a SketchUp model file' unless header[:ok]

        refuse_newer_major!(header)

        resolved = @bridge.realpath(cleaned)
        reject_remote_or_nonskp!(resolved)
        resolved
      end

      def validate_save_skp(path)
        raise ArgumentError, 'path must be an absolute .skp file' unless path.is_a?(String) && !path.strip.empty?

        cleaned = path.strip
        reject_remote_or_nonskp!(cleaned)
        unless absolute_path?(cleaned)
          raise ArgumentError, 'path must be absolute, not a file name. Example: /Users/me/project/house.skp'
        end

        directory = File.dirname(cleaned)
        unless @bridge.directory?(directory)
          raise ArgumentError, "directory does not exist: #{directory}"
        end

        resolved_dir = @bridge.realpath(directory)
        raise ArgumentError, 'path must be a local file, not a network share' if @bridge.remote?(resolved_dir)

        resolved = File.join(resolved_dir, File.basename(cleaned))
        raise ArgumentError, 'path must end with .skp' unless resolved.downcase.end_with?('.skp')
        resolved
      end

      def refuse_newer_major!(header)
        written = header[:written_by_major]
        host = @bridge.respond_to?(:host_major) ? @bridge.host_major : nil
        return if written.nil? || host.nil?
        return if @bridge.respond_to?(:suppress_version_dialog?) && @bridge.suppress_version_dialog?
        return if written <= host

        written_year = 2000 + written
        host_year = 2000 + host
        raise NewerSketchupFile,
              "This file was written by SketchUp #{written_year}. " \
              "Open it in that SketchUp, or ask the architect for a copy saved for #{host_year}."
      end

      def reject_remote_or_nonskp!(path)
        raise ArgumentError, 'path must be a local file, not a network share' if @bridge.remote?(path)
        raise ArgumentError, 'path must end with .skp' unless path.to_s.downcase.end_with?('.skp')
      end

      def absolute_path?(path)
        return File.absolute_path?(path) if File.respond_to?(:absolute_path?)

        path.start_with?('/') || path =~ /\A[A-Za-z]:[\\\/]/
      end

      def session_created_new?(path)
        File.basename(path.to_s).start_with?('sk-mcp-new-')
      end
    end
  end
end
