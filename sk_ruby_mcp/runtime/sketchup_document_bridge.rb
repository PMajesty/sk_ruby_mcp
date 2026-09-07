# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module SkRubyMcp
  module Runtime
    # Единственное место, где session-инструменты вызывают SketchUp API и Launch Services.
    # Методы не ждут и не качают run loop: ожидание делает DocumentSession на следующих тиках.
    class SketchupDocumentBridge
      def initialize(attach: SketchupAttachBridge.new, path_probe: PathProbe.new)
        @attach = attach
        @path_probe = path_probe
      end

      attr_reader :path_probe

      def current_model
        @attach.current_model
      end

      def snapshot
        ModelSnapshotFactory.from_model(current_model)
      end

      def macos?
        @attach.macos?
      end

      def document_count
        @attach.document_count
      end

      def open_path(path)
        macos? ? launch_services_open(path) : windows_open(path)
      end

      def defer_open_until_next_tick?
        !macos?
      end

      def host_major
        defined?(Sketchup) && Sketchup.respond_to?(:version) ? Sketchup.version.to_i : nil
      end

      def suppress_version_dialog?
        major = host_major
        !major.nil? && major >= 26
      end

      def create_new
        @attach.create_blank
      end

      def file?(path)
        @path_probe.file?(path)
      end

      def directory?(path)
        @path_probe.directory?(path)
      end

      def realpath(path)
        @path_probe.realpath(path)
      end

      def remote?(path)
        @path_probe.remote?(path)
      end

      def dispatch_blank
        dest = nil
        source = bundled_blank_path
        return nil unless source && File.file?(source)

        dest = unique_blank_dest
        FileUtils.cp(source, dest)
        open_path(dest)
        dest
      rescue StandardError
        FileUtils.rm_f(dest) if dest
        nil
      end

      def close(model, ignore_changes)
        model.close(ignore_changes)
        true
      end

      def save(model)
        raise ArgumentError, 'model has no path; pass path to model_save' if model.path.to_s.empty?

        require_saved(model.save, 'save')
      end

      def save_as(model, path)
        require_saved(model.save(native_path(path)), 'save-as')
      end

      def save_copy(model, path, version: nil)
        unless model.respond_to?(:save_copy)
          raise ArgumentError, 'This SketchUp build cannot save a copy. Save-as with a path instead.'
        end

        if version
          constant = model.class.const_get("VERSION_#{version}") if model.class.const_defined?("VERSION_#{version}")
          unless constant
            raise ArgumentError, "This host cannot write SketchUp #{version} copies."
          end

          require_saved(model.save_copy(native_path(path), constant), 'save a copy')
        else
          require_saved(model.save_copy(native_path(path)), 'save a copy')
        end
      end

      def canonical(path)
        return nil if path.nil? || path.to_s.empty?
        return File.realpath(path) if File.exist?(path)

        File.expand_path(path)
      rescue StandardError
        File.expand_path(path.to_s)
      end

      def paths_equal?(left, right)
        a = canonical(left)
        b = canonical(right)
        return false if a.nil? || b.nil?

        a.downcase == b.downcase
      end

      private

      def require_saved(saved, action)
        return true if saved

        raise StandardError, "SketchUp refused to #{action} the document"
      end

      def bundled_blank_path
        File.expand_path('../assets/blank.skp', __dir__)
      end

      def unique_blank_dest
        stamp = (Clock.now.to_f * 1000).to_i
        n = 0
        loop do
          suffix = n.zero? ? '' : "-#{n}"
          dest = File.join(Dir.tmpdir, "sk-mcp-new-#{Process.pid}-#{stamp}#{suffix}.skp")
          return dest unless File.exist?(dest)

          n += 1
        end
      end

      def launch_services_open(path)
        year = 2000 + Sketchup.version.to_i
        pid = Process.spawn(
          '/usr/bin/open',
          '-b',
          "com.sketchup.SketchUp.#{year}",
          path,
          out: File::NULL,
          err: File::NULL
        )
        Process.detach(pid)
        :dispatched
      end

      def windows_open(path)
        native = native_path(path)
        status = open_file_with_status(native)
        unless open_file_succeeded?(status)
          raise StandardError, "SketchUp refused to open #{path} (status #{status.inspect})"
        end

        :opened
      end

      def open_file_with_status(path)
        if host_major && host_major >= 26
          Sketchup.open_file(path, with_status: true, show_version_warning_dialog: false)
        else
          Sketchup.open_file(path, with_status: true)
        end
      rescue ArgumentError
        begin
          Sketchup.open_file(path, with_status: true)
        rescue ArgumentError
          Sketchup.open_file(path)
        end
      end

      def open_file_succeeded?(status)
        return false if status.nil? || status == false
        return true if status == true
        return true if load_success_statuses.include?(status)

        false
      end

      def load_success_statuses
        statuses = []
        return statuses unless defined?(Sketchup::Model)

        model = Sketchup::Model
        statuses << model::LOAD_STATUS_SUCCESS if model.const_defined?(:LOAD_STATUS_SUCCESS)
        statuses << model::LOAD_STATUS_SUCCESS_MORE_RECENT if model.const_defined?(:LOAD_STATUS_SUCCESS_MORE_RECENT)
        statuses
      end

      def native_path(path)
        text = path.to_s
        return text if macos?

        filesystem = Encoding.find('filesystem')
        return text unless filesystem

        text.encode(filesystem)
      rescue EncodingError, TypeError
        path.to_s
      end
    end
  end
end
