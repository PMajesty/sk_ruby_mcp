# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Одна орфография пути в ответах: realpath, если файл есть.
    module PathIdentity
      module_function

      def display(path)
        return nil if path.nil? || path.to_s.empty?

        cleaned = path.to_s
        return File.realpath(cleaned) if File.exist?(cleaned)

        parent = File.dirname(cleaned)
        return File.join(File.realpath(parent), File.basename(cleaned)) if File.directory?(parent)

        cleaned
      rescue StandardError
        path.to_s
      end
    end
  end
end
