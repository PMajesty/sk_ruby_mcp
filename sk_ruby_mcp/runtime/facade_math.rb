# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Чистая математика фасадного пакета: проекция камеры, оси грани, этажные ячейки,
    # разворачивание ведомости проёмов в метры и сравнение ведомости с моделью. Без SketchUp.
    module FacadeMath
      KINDS = %w[small_window large_window glass_door storefront custom].freeze
      EDGES = %w[left right top bottom].freeze
      KIND_DEFAULTS = {
        'small_window' => { 'y0' => 0.25, 'y1' => 1.0, 'frame_edges' => %w[left right bottom] },
        'large_window' => { 'y0' => 0.0, 'y1' => 1.0, 'frame_edges' => %w[left right] },
        'glass_door' => { 'y0' => 0.0, 'y1' => 0.66, 'frame_edges' => %w[left right top] },
        'storefront' => { 'y0' => 0.0, 'y1' => 0.8, 'frame_edges' => %w[left right top] },
        'custom' => { 'y0' => nil, 'y1' => nil, 'frame_edges' => EDGES }
      }.freeze
      OPENING_DEFAULTS = {
        'kind' => 'small_window',
        'frame_w_m' => 0.30,
        'frame_out_m' => 0.15,
        'recess_m' => 0.25,
        'frame_color' => '#F4F2EE',
        'glass_color' => '#4A7FB5',
        'mullions' => 0,
        'mullion_w_m' => 0.12,
        'transom' => false,
        'count' => 1
      }.freeze
      MIN_OPENING_M = 0.15
      EDGE_TOL_M = 0.02
      OVERLAP_TOL_M = 0.01
      MIN_CELL_M = 1.0
      MAX_EXPANDED = 400
      ID_LEVELS = [0, 51, 102, 153, 204, 255].freeze
      ID_STRIDE = 67

      module_function

      def sub3(a, b)
        [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
      end

      def dot3(a, b)
        (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2])
      end

      def cross3(a, b)
        [
          (a[1] * b[2]) - (a[2] * b[1]),
          (a[2] * b[0]) - (a[0] * b[2]),
          (a[0] * b[1]) - (a[1] * b[0])
        ]
      end

      def norm3(a)
        len = Math.sqrt(dot3(a, a))
        return nil if len < 1.0e-12

        [a[0] / len, a[1] / len, a[2] / len]
      end

      # Ортонормированный базис камеры: forward к цели, right вправо на экране, up вверх на экране.
      def camera_basis(eye, target, up)
        forward = norm3(sub3(target, eye))
        return nil if forward.nil?

        right = norm3(cross3(forward, up))
        return nil if right.nil?

        { forward: forward, right: right, up: cross3(right, forward) }
      end

      def focal_px(fov_deg, width, height, fov_is_height)
        half = fov_deg.to_f * Math::PI / 360.0
        return nil if half <= 0.0 || half >= Math::PI / 2.0

        base = fov_is_height ? height.to_f : width.to_f
        (base / 2.0) / Math.tan(half)
      end

      # Пиксель точки в кадре width×height; nil, если точка за камерой.
      def project(basis, eye, point, width, height, focal)
        d = sub3(point, eye)
        depth = dot3(d, basis[:forward])
        return nil if depth <= 1.0e-6

        x = dot3(d, basis[:right])
        y = dot3(d, basis[:up])
        [(width / 2.0) + (focal * x / depth), (height / 2.0) - (focal * y / depth)]
      end

      # Оси грани по внешней нормали: right = Z × n (слева направо для зрителя снаружи), up = Z в плоскости.
      def frame_axes(normal)
        n = norm3(normal)
        return nil if n.nil?

        world_up = [0.0, 0.0, 1.0]
        up = norm3(sub3(world_up, [n[0] * n[2], n[1] * n[2], n[2] * n[2]]))
        if up.nil?
          fallback = [0.0, 1.0, 0.0]
          up = norm3(sub3(fallback, [n[0] * n[1], n[1] * n[1], n[2] * n[1]]))
        end
        return nil if up.nil?

        right = norm3(cross3(up, n))
        return nil if right.nil?

        [right, up]
      end

      # Этажные ячейки между z0 и z1 по отметкам плит; при отсутствии плит режет по storey_h_m.
      def storey_cells(z0, z1, plate_levels, storey_h_m: nil)
        bottom = z0.to_f
        top = z1.to_f
        return [] if top - bottom < MIN_CELL_M

        levels = Array(plate_levels).map(&:to_f).select { |z| z > bottom + MIN_CELL_M && z < top - MIN_CELL_M }
        if levels.empty? && storey_h_m.to_f > 0.5
          z = bottom + storey_h_m.to_f
          while z < top - MIN_CELL_M
            levels << z
            z += storey_h_m.to_f
          end
        end
        all = ([bottom, top] + levels).map { |level| level.round(3) }.uniq.sort
        cells = []
        all.each_cons(2).with_index do |(lo, hi), index|
          cells << { 'index' => index, 'z0_m' => lo, 'z1_m' => hi, 'height_m' => (hi - lo).round(3) }
        end
        cells
      end

      def kind_valid?(kind)
        KINDS.include?(kind.to_s)
      end

      # Раскрывает ведомость: defaults + item, count колонок внутри span x0..x1, storeys как список или "all".
      # faces_by_id: { face id => { 'width_m' => .., 'cells' => [...] } }.
      def expand_items(items, defaults, faces_by_id)
        expanded = []
        errors = []
        Array(items).each_with_index do |item, index|
          unless item.is_a?(Hash)
            errors << { 'item' => index, 'error' => 'item must be an object' }
            next
          end
          explicit = stringify(item)
          merged = OPENING_DEFAULTS.merge(stringify(defaults)).merge(explicit)
          face = faces_by_id[merged['face'].to_s] || faces_by_id[merged['face']] || {}
          storeys = storey_list(explicit, merged, face['cells'])
          if storeys.nil?
            errors << { 'item' => index, 'error' => 'storey, storeys or z0_m/z1_m is required' }
            next
          end
          count = merged['count'].to_i
          count = 1 if count < 1
          if count > 1 && (merged['x0'].nil? || merged['x1'].nil?)
            errors << { 'item' => index, 'error' => 'count > 1 needs an x0..x1 span (fractions of the face width)' }
            next
          end
          columns = columns_for(merged, count, face['width_m'].to_f)
          if columns.is_a?(String)
            errors << { 'item' => index, 'error' => columns }
            next
          end
          storeys.each do |storey|
            columns.each_with_index do |(x0, x1), column|
              piece = merged.merge('storey' => storey, 'item' => index, 'column' => column)
              piece['x0'] = x0 unless x0.nil?
              piece['x1'] = x1 unless x1.nil?
              expanded << piece
            end
          end
          if expanded.length > MAX_EXPANDED
            errors << { 'item' => index, 'error' => "more than #{MAX_EXPANDED} openings in one call" }
            break
          end
        end
        { 'items' => expanded, 'errors' => errors }
      end

      # Явные ключи элемента важнее defaults: storey элемента побеждает storeys из defaults.
      def storey_list(explicit, merged, cells)
        [explicit, merged].each do |source|
          return [nil] if source.key?('z0_m') && source.key?('z1_m')
          if source.key?('storeys')
            value = source['storeys']
            return (cells || []).map { |cell| cell['index'] } if value.to_s == 'all'
            return value.map(&:to_i) if value.is_a?(Array)
          end
          return [source['storey'].to_i] if source.key?('storey') && !source['storey'].nil?
        end
        nil
      end

      # Колонки: count проёмов внутри x0..x1 (доли ширины грани) с равными промежутками.
      # Возвращает строку с ошибкой, когда колонки не помещаются в интервал.
      def columns_for(merged, count, face_width_m)
        x0 = merged['x0']
        x1 = merged['x1']
        return [[x0, x1]] if count <= 1 || x0.nil? || x1.nil?

        span = x1.to_f - x0.to_f
        return 'x1 must be greater than x0' if span <= 0

        each = if merged['w']
                 merged['w'].to_f
               elsif merged['width_m'] && face_width_m.positive?
                 merged['width_m'].to_f / face_width_m
               else
                 span / (count * 1.6)
               end
        gap = (span - (count * each)) / (count + 1).to_f
        if gap.negative?
          return "#{count} openings of #{(each * 100).round(1)}% each do not fit into x0..x1 (#{(span * 100).round(1)}% of the face)"
        end

        (0...count).map do |column|
          start = x0.to_f + gap + (column * (each + gap))
          [start.round(5), (start + each).round(5)]
        end
      end

      # Переводит один раскрытый элемент в метры грани: u от левого края, z мировые.
      def resolve_opening(piece, face, cells)
        kind = piece['kind'].to_s
        return failure(piece, "kind must be one of #{KINDS.join(', ')}") unless kind_valid?(kind)

        width = face['width_m'].to_f
        horizontal = horizontal_span(piece, width)
        return failure(piece, horizontal) if horizontal.is_a?(String)

        vertical = vertical_span(piece, kind, cells)
        return failure(piece, vertical) if vertical.is_a?(String)

        u0, u1 = horizontal
        z0, z1 = vertical
        return failure(piece, "opening narrower than #{MIN_OPENING_M} m") if u1 - u0 < MIN_OPENING_M
        return failure(piece, "opening lower than #{MIN_OPENING_M} m") if z1 - z0 < MIN_OPENING_M
        if u0 < -EDGE_TOL_M || u1 > width + EDGE_TOL_M
          return failure(piece, "outside the face horizontally (u #{u0.round(2)}..#{u1.round(2)} of #{width.round(2)} m)")
        end
        if z0 < face['z0_m'].to_f - EDGE_TOL_M || z1 > face['z1_m'].to_f + EDGE_TOL_M
          return failure(piece, "outside the face vertically (z #{z0.round(2)}..#{z1.round(2)} of #{face['z0_m']}..#{face['z1_m']} m)")
        end

        edges = frame_edges_for(piece, kind)
        return failure(piece, "frame_edges must be a subset of #{EDGES.join(', ')}") if edges.nil?

        {
          'ok' => true,
          'face' => piece['face'],
          'kind' => kind,
          'u0_m' => u0.round(4),
          'u1_m' => u1.round(4),
          'width_m' => (u1 - u0).round(4),
          'z0_m' => z0.round(4),
          'z1_m' => z1.round(4),
          'height_m' => (z1 - z0).round(4),
          'v0_m' => (z0 - face['z0_m'].to_f).round(4),
          'storey' => piece['storey'],
          'frame_edges' => edges,
          'frame_w_m' => positive_or(piece['frame_w_m'], OPENING_DEFAULTS['frame_w_m']),
          'frame_out_m' => positive_or(piece['frame_out_m'], OPENING_DEFAULTS['frame_out_m']),
          'recess_m' => positive_or(piece['recess_m'], OPENING_DEFAULTS['recess_m']),
          'frame_color' => piece['frame_color'],
          'glass_color' => piece['glass_color'],
          'mullions' => [[piece['mullions'].to_i, 0].max, 12].min,
          'mullion_w_m' => positive_or(piece['mullion_w_m'], OPENING_DEFAULTS['mullion_w_m']),
          'transom' => piece['transom'] == true,
          'label' => piece['label'].to_s,
          'item' => piece['item'],
          'column' => piece['column']
        }
      end

      def horizontal_span(piece, width)
        if piece['x0'] && piece['x1']
          return [piece['x0'].to_f * width, piece['x1'].to_f * width]
        end
        if piece['u0_m'] && piece['width_m']
          u0 = piece['u0_m'].to_f
          return [u0, u0 + piece['width_m'].to_f]
        end
        if piece['x_center'] && piece['width_m']
          center = piece['x_center'].to_f * width
          half = piece['width_m'].to_f / 2.0
          return [center - half, center + half]
        end
        if piece['x0'] && piece['width_m']
          u0 = piece['x0'].to_f * width
          return [u0, u0 + piece['width_m'].to_f]
        end

        'x0 and x1 (fractions of the face width), or u0_m and width_m, or x_center and width_m are required'
      end

      def vertical_span(piece, kind, cells)
        if piece['z0_m'] && piece['z1_m']
          return [piece['z0_m'].to_f, piece['z1_m'].to_f]
        end

        storey = piece['storey']
        return 'storey or z0_m/z1_m is required' if storey.nil?

        cell = Array(cells).find { |row| row['index'] == storey.to_i }
        return "storey #{storey} does not exist on this face (#{Array(cells).length} cells)" if cell.nil?

        base = cell['z0_m'].to_f
        height = cell['z1_m'].to_f - base
        y0 = piece.key?('sill_m') ? piece['sill_m'].to_f / height : fraction_or_default(piece['y0'], kind, 'y0')
        y1 = piece.key?('head_m') ? piece['head_m'].to_f / height : fraction_or_default(piece['y1'], kind, 'y1')
        return 'custom kind needs y0 and y1 (fractions of the storey) or sill_m and head_m' if y0.nil? || y1.nil?
        return 'y0 must be below y1' if y1 <= y0

        [base + (y0 * height), base + (y1 * height)]
      end

      def fraction_or_default(value, kind, key)
        return value.to_f unless value.nil?

        KIND_DEFAULTS.fetch(kind).fetch(key)
      end

      def frame_edges_for(piece, kind)
        edges = piece['frame_edges']
        return KIND_DEFAULTS.fetch(kind).fetch('frame_edges') if edges.nil?
        return nil unless edges.is_a?(Array)

        names = edges.map(&:to_s)
        return nil unless (names - EDGES).empty?

        names.uniq
      end

      def positive_or(value, default)
        n = value.to_f
        n.positive? ? n : default
      end

      def failure(piece, message)
        { 'ok' => false, 'face' => piece['face'], 'item' => piece['item'], 'column' => piece['column'], 'error' => message }
      end

      # Два проёма на одной грани пересекаются по площади (касание краями не считается).
      def overlap?(a, b, tol_m: OVERLAP_TOL_M)
        return false unless a['face'].to_s == b['face'].to_s

        a_u1 = a['u1_m'] || (a['u0_m'].to_f + a['width_m'].to_f)
        b_u1 = b['u1_m'] || (b['u0_m'].to_f + b['width_m'].to_f)
        a['u0_m'].to_f < b_u1.to_f - tol_m && b['u0_m'].to_f < a_u1.to_f - tol_m &&
          a['z0_m'].to_f < b['z1_m'].to_f - tol_m && b['z0_m'].to_f < a['z1_m'].to_f - tol_m
      end

      # Отбирает из разрешённых проёмов те, что не пересекают ни занятые, ни ранее принятые;
      # пересекающиеся возвращаются как ошибки с указанием соседа.
      def reject_overlaps(resolved, occupied = [])
        accepted = []
        errors = []
        Array(resolved).each do |spec|
          clash = (Array(occupied) + accepted).find { |other| overlap?(other, spec) }
          if clash
            errors << failure(spec, "overlaps #{describe_opening(clash)} on face #{spec['face']}")
          else
            accepted << spec
          end
        end
        { 'accepted' => accepted, 'errors' => errors }
      end

      def describe_opening(opening)
        return "existing opening #{opening['id']}" if opening['id']

        column = opening['column'] ? " column #{opening['column']}" : ''
        "item #{opening['item']}#{column}"
      end

      # Сравнение ведомости с проёмами в модели: matched, mismatched (та же грань и вид, но сдвиг), missing, extra.
      def diff(expected, live, tol_m: 0.15)
        remaining = Array(live).dup
        matched = []
        mismatched = []
        missing = []
        Array(expected).each do |want|
          hit = remaining.find { |have| same_opening?(want, have, tol_m) }
          if hit
            remaining.delete(hit)
            matched << { 'expected' => want, 'live_id' => hit['id'] }
            next
          end
          near = remaining.find { |have| overlapping?(want, have) }
          if near
            remaining.delete(near)
            mismatched << { 'expected' => want, 'live' => near, 'delta' => deltas(want, near) }
          else
            missing << want
          end
        end
        {
          'ok' => mismatched.empty? && missing.empty? && remaining.empty?,
          'matched' => matched.length,
          'mismatched' => mismatched,
          'missing' => missing,
          'extra' => remaining,
          'tolerance_m' => tol_m
        }
      end

      def same_opening?(want, have, tol)
        return false unless want['face'].to_s == have['face'].to_s
        return false unless want['kind'].to_s == have['kind'].to_s

        %w[u0_m width_m z0_m z1_m].all? { |key| (want[key].to_f - have[key].to_f).abs <= tol }
      end

      def overlapping?(want, have)
        return false unless want['face'].to_s == have['face'].to_s

        u_overlap = [want['u0_m'].to_f + want['width_m'].to_f, have['u0_m'].to_f + have['width_m'].to_f].min -
                    [want['u0_m'].to_f, have['u0_m'].to_f].max
        z_overlap = [want['z1_m'].to_f, have['z1_m'].to_f].min - [want['z0_m'].to_f, have['z0_m'].to_f].max
        u_overlap.positive? && z_overlap.positive?
      end

      def deltas(want, have)
        %w[u0_m width_m z0_m z1_m].each_with_object({}) do |key, acc|
          acc[key] = (have[key].to_f - want[key].to_f).round(3)
        end.merge('kind' => [want['kind'], have['kind']])
      end

      # Различимые плоские цвета для ID-прохода; индекс 0 никогда не чёрный (чёрный — фон).
      def id_color(index)
        combos = ID_LEVELS.length**3
        slot = ((index.to_i * ID_STRIDE) + 1) % (combos - 1)
        slot += 1
        r = ID_LEVELS[(slot / (ID_LEVELS.length**2)) % ID_LEVELS.length]
        g = ID_LEVELS[(slot / ID_LEVELS.length) % ID_LEVELS.length]
        b = ID_LEVELS[slot % ID_LEVELS.length]
        [r, g, b]
      end

      def stringify(hash)
        return {} unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
      end
    end
  end
end
