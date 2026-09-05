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

      def rect_area_m2(rect)
        width = rect[2].to_f - rect[0].to_f
        depth = rect[3].to_f - rect[1].to_f
        return 0.0 if width <= 0.0 || depth <= 0.0

        width * depth
      end

      def intersect_rect(a, b)
        [
          [a[0].to_f, b[0].to_f].max,
          [a[1].to_f, b[1].to_f].max,
          [a[2].to_f, b[2].to_f].min,
          [a[3].to_f, b[3].to_f].min
        ]
      end

      # Площадь объединения осевых прямоугольников [xmin, ymin, xmax, ymax] в м².
      def union_rects_m2(rects)
        list = Array(rects).select { |rect| rect.is_a?(Array) && rect.size >= 4 }
        return 0.0 if list.empty?
        return rect_area_m2(list[0]) if list.length == 1
        return rect_area_m2(list[0]) + rect_area_m2(list[1]) - rect_area_m2(intersect_rect(list[0], list[1])) if list.length == 2

        n = list.length
        n = 12 if n > 12
        list = list.first(n)
        total = 0.0
        1.upto(n) do |k|
          sign = k.odd? ? 1.0 : -1.0
          list.combination(k) do |subset|
            acc = subset[0]
            subset[1..-1].each { |rect| acc = intersect_rect(acc, rect) }
            total += sign * rect_area_m2(acc)
          end
        end
        total
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
        # sill_m — низ первого ряда. Лишняя высота только между рядами и над последним, не под первым.
        gap_v = rows_n > 1 ? extra_v / (rows_n - 1).to_f : 0.0
        slots = []
        row = 0
        while row < rows_n
          col = 0
          while col < cols_n
            slots << {
              'u' => pad + gap_u + (col * (width + gap_u)),
              'v' => sill_h + (row * (height + gap_v)),
              'w' => width,
              'h' => height
            }
            col += 1
          end
          row += 1
        end
        { 'ok' => true, 'slots' => slots, 'gap_u' => gap_u, 'gap_v' => gap_v }
      end

      def slot_uv_in(u_min_in, v_min_in, slot)
        u0 = u_min_in.to_f + m_to_in(slot['u'])
        v0 = v_min_in.to_f + m_to_in(slot['v'])
        [u0, v0, u0 + m_to_in(slot['w']), v0 + m_to_in(slot['h'])]
      end

      def perimeter_plan(site_w:, site_d:, depth:, origin:)
        width = site_w.to_f
        depth_y = site_d.to_f
        thick = depth.to_f
        origin = origin.nil? ? [0.0, 0.0, 0.0] : origin
        ox = origin[0].to_f
        oy = origin[1].to_f
        oz = origin[2].to_f
        if width <= 0.0 || depth_y <= 0.0 || thick <= 0.0
          return failure('site_w_m, site_d_m and depth_m must be positive')
        end
        if width <= (2.0 * thick) || depth_y <= (2.0 * thick)
          return failure(
            "depth_m #{thick} leaves no courtyard in a #{width}×#{depth_y} m site " \
            '(need site > 2×depth on both axes)'
          )
        end

        inner_w = width - (2.0 * thick)
        inner_d = depth_y - (2.0 * thick)
        wings = [
          {
            'facing' => 'south',
            'origin_m' => [ox, oy, oz],
            'size_xy_m' => [width, thick]
          },
          {
            'facing' => 'north',
            'origin_m' => [ox, oy + depth_y - thick, oz],
            'size_xy_m' => [width, thick]
          },
          {
            'facing' => 'west',
            'origin_m' => [ox, oy + thick, oz],
            'size_xy_m' => [thick, inner_d]
          },
          {
            'facing' => 'east',
            'origin_m' => [ox + width - thick, oy + thick, oz],
            'size_xy_m' => [thick, inner_d]
          }
        ]
        footprint = (2.0 * width * thick) + (2.0 * thick * inner_d)
        {
          'ok' => true,
          'wings' => wings,
          'courtyard_m' => [inner_w, inner_d],
          'courtyard_m2' => inner_w * inner_d,
          'footprint_m2' => footprint,
          'site_m2' => width * depth_y
        }
      end

      def failure(message)
        { 'ok' => false, 'error' => 'does_not_fit', 'message' => message, 'slots' => [] }
      end
    end
  end
end
