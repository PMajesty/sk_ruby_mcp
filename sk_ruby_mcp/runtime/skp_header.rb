# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Заголовок .skp: магия UTF-16LE и запись {major.minor.build}.
    module SkpHeader
      MAGIC = [0xFF, 0xFE, 0xFF, 0x0E].pack('C*')
      LABEL = "SketchUp Model".encode('UTF-16LE').b
      READ_BYTES = 256
      VERSION = /\{(\d+)\.(\d+)\.(\d+)\}/.freeze

      module_function

      def parse(path)
        data = File.binread(path.to_s, READ_BYTES).to_s.b
        unless data.start_with?(MAGIC) && data.byteslice(MAGIC.bytesize, LABEL.bytesize) == LABEL
          return { ok: false, error: 'not_a_skp_file' }
        end

        text = data.force_encoding('UTF-16LE').encode('UTF-8', invalid: :replace, undef: :replace)
        match = VERSION.match(text)
        major = match ? Integer(match[1], 10) : nil
        {
          ok: true,
          written_by_major: major,
          written_by: match && match[0]
        }
      rescue Errno::ENOENT, Errno::EISDIR, Errno::EACCES
        { ok: false, error: 'not_a_skp_file' }
      end
    end
  end
end
