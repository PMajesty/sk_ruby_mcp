# frozen_string_literal: true

require 'stringio'

module SkRubyMcp
  module Runtime
    # Буфер для подмены $stdout / $stderr на время выполнения кода агента.
    # Наследует StringIO, чтобы puts / print / p / printf / << работали как с обычным IO,
    # но ограничивает объём: байты сверх лимита отбрасываются и учитываются в dropped_bytes.
    class OutputCapture < StringIO
      attr_reader :dropped_bytes

      def initialize(max_bytes)
        super(String.new(encoding: Encoding::UTF_8))
        @max_bytes = max_bytes
        @dropped_bytes = 0
      end

      def write(*chunks)
        chunks.sum do |chunk|
          text = TextTrimmer.utf8(chunk)
          piece = fit(text)
          super(piece) unless piece.empty?
          text.bytesize
        end
      end

      def truncated?
        @dropped_bytes > 0
      end

      private

      # Часть текста, помещающаяся в лимит; остаток учитывается как отброшенный.
      def fit(text)
        remaining = @max_bytes - string.bytesize
        return drop(text) if remaining <= 0
        return text if text.bytesize <= remaining

        @dropped_bytes += text.bytesize - remaining
        text.byteslice(0, remaining).scrub('')
      end

      def drop(text)
        @dropped_bytes += text.bytesize
        ''
      end
    end
  end
end
