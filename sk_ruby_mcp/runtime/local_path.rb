# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Абсолютный локальный путь для фасадных файлов: не UNC и не сетевой диск.
    module LocalPath
      EXAMPLE = '/Users/me/project/house.png or C:\\Users\\me\\project\\house.png'

      module_function

      def existing_file(path, probe:, example: EXAMPLE)
        cleaned = require_absolute(path, example: example)
        refuse_remote!(cleaned, probe)
        unless probe.file?(cleaned)
          raise ArgumentError, "#{cleaned.inspect} is not an existing file"
        end

        resolved = probe.realpath(cleaned)
        refuse_remote!(resolved, probe)
        resolved
      end

      def writable_file(path, probe:, example: EXAMPLE)
        cleaned = require_absolute(path, example: example)
        refuse_remote!(cleaned, probe)
        parent = File.dirname(cleaned)
        unless probe.directory?(parent)
          raise ArgumentError, "directory does not exist: #{parent}"
        end

        resolved_parent = probe.realpath(parent)
        refuse_remote!(resolved_parent, probe)
        if probe.file?(cleaned)
          refuse_remote!(probe.realpath(cleaned), probe)
        end
        cleaned
      end

      def require_absolute(path, example: EXAMPLE)
        raw = path.to_s.strip
        raise ArgumentError, 'path is required' if raw.empty?
        unless absolute?(raw)
          raise ArgumentError, "path must be absolute, not a file name. Example: #{example}"
        end

        File.expand_path(raw)
      end

      def refuse_remote!(path, probe)
        return unless probe.remote?(path)

        raise ArgumentError, 'path must be a local file, not a network share'
      end

      def absolute?(path)
        return File.absolute_path?(path) if File.respond_to?(:absolute_path?)

        path.start_with?('/') || path.match?(/\A[A-Za-z]:[\\\/]/)
      end
    end
  end
end
