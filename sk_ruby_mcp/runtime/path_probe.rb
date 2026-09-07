# frozen_string_literal: true

require 'fiddle'

module SkRubyMcp
  module Runtime
    # Узкий зонд пути: local vs UNC/сеть. Без open/close документа.
    class PathProbe
      DRIVE_UNKNOWN = 0
      DRIVE_NO_ROOT_DIR = 1
      DRIVE_REMOTE = 4
      NETWORK_FS = %w[smbfs nfs afp afpfs cifs webdav nfs4 url].freeze

      def remote?(path)
        cleaned = path.to_s.tr('\\', '/')
        return true if cleaned.start_with?('//')
        return windows_network_drive?(cleaned) if windows_path?(cleaned)

        type = mount_fs_type(existing_probe(cleaned))
        return false if type.nil? || type.empty?

        NETWORK_FS.include?(type.downcase)
      end

      def file?(path)
        File.file?(path.to_s)
      end

      def directory?(path)
        File.directory?(path.to_s)
      end

      def realpath(path)
        File.exist?(path.to_s) ? File.realpath(path.to_s) : File.expand_path(path.to_s)
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
        return true unless letter

        type = windows_drive_type("#{letter}:\\")
        return true if type.nil?

        type == DRIVE_REMOTE || type == DRIVE_UNKNOWN || type == DRIVE_NO_ROOT_DIR
      rescue StandardError
        true
      end

      def windows_drive_type(root)
        kernel = Fiddle.dlopen('kernel32.dll')
        get_drive_type = Fiddle::Function.new(
          kernel['GetDriveTypeW'],
          [Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_ULONG
        )
        wide = "#{root}\0".encode('UTF-16LE')
        get_drive_type.call(Fiddle::Pointer[wide])
      end
    end
  end
end
