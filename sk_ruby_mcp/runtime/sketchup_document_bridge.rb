# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module SkRubyMcp
  module Runtime
    # Единственное место, где session-инструменты вызывают SketchUp API и Launch Services.
    # Методы не ждут и не качают run loop: ожидание делает DocumentSession на следующих тиках.
    class SketchupDocumentBridge
      def initialize(attach: SketchupAttachBridge.new)
        @attach = attach
      end

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
        File.file?(path.to_s)
      end

      def directory?(path)
        File.directory?(path.to_s)
      end

      def realpath(path)
        File.realpath(path.to_s)
      end

      NETWORK_FS = %w[smbfs nfs afp afpfs cifs webdav nfs4 url].freeze

      def remote?(path)
        cleaned = path.to_s.tr('\\', '/')
        return true if cleaned.start_with?('//')
        return windows_network_drive?(cleaned) if windows_path?(cleaned)

        type = mount_fs_type(existing_probe(cleaned))
        return false if type.nil? || type.empty?

        NETWORK_FS.include?(type.downcase)
      end

      def mount_fs_type(path)
        real = mount_realpath(path)
        best_point = nil
        best_type = nil
        mount_entries.each do |mountpoint, fstype|
          next unless path_on_mount?(real, mountpoint)
          next unless best_point.nil? || mountpoint.length > best_point.length

          best_point = mountpoint
          best_type = fstype
        end
        best_type
      end

      def mount_entries
        IO.popen(['/sbin/mount'], err: File::NULL, &:read).to_s.each_line.map do |line|
          match = line.match(/\A.+ on (.+) \(([^,)]+)/)
          next unless match

          [match[1], match[2].strip]
        end.compact
      rescue StandardError
        []
      end

      def mount_realpath(path)
        File.exist?(path.to_s) ? File.realpath(path.to_s) : File.expand_path(path.to_s)
      rescue StandardError
        path.to_s
      end

      def path_on_mount?(real, mountpoint)
        return real.start_with?('/') if mountpoint == '/'

        real == mountpoint || real.start_with?("#{mountpoint}/")
      end

      def existing_probe(path)
        return path if File.exist?(path.to_s)

        parent = File.dirname(path.to_s)
        File.exist?(parent) ? parent : path
      end

      def windows_path?(path)
        path.to_s.match?(/\A[A-Za-z]:/)
      end

      def windows_network_drive?(path)
        letter = path.to_s[/\A([A-Za-z]):/, 1]
        return false unless letter

        output = IO.popen(['cmd.exe', '/c', "net use #{letter}:"], err: File::NULL, &:read)
        output.to_s.match?(/Remote name|\\\\|\/\//)
      rescue StandardError
        false
      end

      def dispatch_blank
        source = bundled_blank_path
        return nil unless source && File.file?(source)

        dest = unique_blank_dest
        FileUtils.cp(source, dest)
        open_path(dest)
        dest
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
        require_saved(model.save(path), 'save-as')
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

          require_saved(model.save_copy(path, constant), 'save a copy')
        else
          require_saved(model.save_copy(path), 'save a copy')
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
        if Sketchup.version.to_i >= 26
          Sketchup.open_file(path, with_status: true, show_version_warning_dialog: false)
        else
          Sketchup.open_file(path, with_status: true)
        end
      rescue ArgumentError
        Sketchup.open_file(path, with_status: true)
      end
    end
  end
end
