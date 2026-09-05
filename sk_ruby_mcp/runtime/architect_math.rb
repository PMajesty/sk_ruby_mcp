# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Чистая арифметика метров и сетки проёмов. Без SketchUp, чтобы тесты жили вне приложения.
    module ArchitectMath
      INCHES_PER_M = 39.37007874015748
      FACING = {
        'north' => [0.0, 1.0, 0.0],
        'south' => [0.0, -1.0, 0.0],
        'east' => [1.0, 0.0, 0.0],
        'west' => [-1.0, 0.0, 0.0],
        'n' => [0.0, 1.0, 0.0],
        's' => [0.0, -1.0, 0.0],
        'e' => [1.0, 0.0, 0.0],
        'w' => [-1.0, 0.0, 0.0]
      }.freeze

      module_function

      def m_to_in(metres)
        metres.to_f * INCHES_PER_M
      end

      def in_to_m(inches)
        inches.to_f / INCHES_PER_M
      end

      def footprint_m2(size_m)
        size_m[0].to_f * size_m[1].to_f
      end

      def storeys_guess(height_m, storey_h_m)
        h = height_m.to_f
        storey = storey_h_m.to_f
        return 1 if storey <= 0.0 || h <= 0.0

        n = (h / storey).floor
        n < 1 ? 1 : n
      end

      def facing_vector(name)
        FACING[name.to_s.strip.downcase]
      end

      def parse_hex_color(text)
        raw = text.to_s.strip.sub(/\A#/, '')
        if raw.length == 3 && raw =~ /\A[0-9a-fA-F]{3}\z/
          return raw.chars.map { |ch| (ch * 2).to_i(16) }
        end
        if raw.length == 6 && raw =~ /\A[0-9a-fA-F]{6}\z/
          return [raw[0, 2].to_i(16), raw[2, 2].to_i(16), raw[4, 2].to_i(16)]
        end

        nil
      end

      def grid_slots(face_w:, face_h:, cols:, rows:, win_w:, win_h:, sill:, margin:)
        cols_n = cols.to_i
        rows_n = rows.to_i
        width = win_w.to_f
        height = win_h.to_f
        sill_h = sill.to_f
        pad = margin.to_f
        if cols_n < 1 || rows_n < 1
          return failure('cols and rows must be integers >= 1')
        end
        if width <= 0.0 || height <= 0.0
          return failure('width_m and height_m must be positive')
        end
        if pad < 0.0 || sill_h < 0.0
          return failure('sill_m and margin_m must be >= 0')
        end

        usable_w = face_w.to_f - (2.0 * pad)
        usable_h = face_h.to_f - pad - sill_h
        need_w = cols_n * width
        need_h = rows_n * height
        if usable_w + 1.0e-6 < need_w || usable_h + 1.0e-6 < need_h
          return failure(
            "windows do not fit: need #{need_w.round(3)}×#{need_h.round(3)} m in " \
            "#{usable_w.round(3)}×#{usable_h.round(3)} m usable (face #{face_w.to_f.round(3)}×#{face_h.to_f.round(3)} m, " \
            "sill #{sill_h} m, margin #{pad} m)"
          )
        end

        extra_u = usable_w - need_w
        extra_v = usable_h - need_h
        gap_u = extra_u / (cols_n + 1).to_f
        gap_v = extra_v / (rows_n + 1).to_f
        slots = []
        row = 0
        while row < rows_n
          col = 0
          while col < cols_n
            slots << {
              'u' => pad + gap_u + (col * (width + gap_u)),
              'v' => sill_h + gap_v + (row * (height + gap_v)),
              'w' => width,
              'h' => height
            }
            col += 1
          end
          row += 1
        end
        { 'ok' => true, 'slots' => slots, 'gap_u' => gap_u, 'gap_v' => gap_v }
      end

      def failure(message)
        { 'ok' => false, 'error' => 'does_not_fit', 'message' => message, 'slots' => [] }
      end
    end
  end
end
