# frozen_string_literal: true

module SkRubyMcp
  # Приведение текста к валидному UTF-8 и усечение по байтам с сохранением начала и конца.
  module TextTrimmer
    REPLACEMENT = "\uFFFD"
    HEAD_SHARE = 0.7

    class << self
      def utf8(text)
        string = text.to_s
        case string.encoding
        when Encoding::UTF_8
          string.scrub(REPLACEMENT)
        when Encoding::ASCII_8BIT, Encoding::US_ASCII
          string.dup.force_encoding(Encoding::UTF_8).scrub(REPLACEMENT)
        else
          string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT)
        end
      rescue EncodingError
        string.dup.force_encoding(Encoding::UTF_8).scrub(REPLACEMENT)
      end

      # Возвращает [текст, усечён?]. Середина заменяется маркером с числом пропущенных байт.
      def truncate(text, max_bytes)
        string = utf8(text)
        return [string, false] if string.bytesize <= max_bytes

        head_bytes = (max_bytes * HEAD_SHARE).floor
        tail_bytes = max_bytes - head_bytes
        omitted = string.bytesize - head_bytes - tail_bytes
        head = string.byteslice(0, head_bytes).scrub('')
        tail = string.byteslice(string.bytesize - tail_bytes, tail_bytes).scrub('')
        ["#{head}\n... [truncated: #{omitted} bytes omitted] ...\n#{tail}", true]
      end
    end
  end
end
