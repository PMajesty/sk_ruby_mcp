# frozen_string_literal: true

module SkRubyMcp
  # Журнал расширения: пишет в консоль Ruby SketchUp и хранит кольцевой буфер последних записей.
  # Приёмник фиксируется при загрузке, потому что во время execute_ruby $stdout подменяется буфером захвата.
  module Log
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze
    PREFIX = '[SkRubyMcp]'
    RING_SIZE = 200

    @level = :info
    @sink = $stdout
    @entries = []

    class << self
      attr_accessor :sink
      attr_reader :level

      def level=(new_level)
        raise ArgumentError, "unknown log level: #{new_level.inspect}" unless LEVELS.key?(new_level)

        @level = new_level
      end

      def entries
        @entries.dup
      end

      LEVELS.each_key do |name|
        define_method(name) { |message| write(name, message) }
      end

      private

      def write(level, message)
        @entries << [Time.now, level, message.to_s]
        @entries.shift while @entries.size > RING_SIZE
        return if LEVELS[level] < LEVELS[@level]

        @sink.puts("#{PREFIX} #{level.to_s.upcase}: #{message}")
      rescue StandardError
        nil
      end
    end
  end
end
