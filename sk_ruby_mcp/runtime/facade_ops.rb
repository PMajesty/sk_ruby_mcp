# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Фасадные операции над одним объектом (группой или компонентом): грани с пиксельными
    # квадратами, проёмы как приклеенные режущие компоненты, пояса как группы, покраска, ведомость.
    # Стена никогда не режется: удаление элемента возвращает исходную массу.
    class FacadeOps
      include SceneGeometry

      DICT = FacadeScene::DICT
      ROLE_OPENING = FacadeScene::ROLE_OPENING
      ROLE_BAND = FacadeScene::ROLE_BAND
      VERTICAL_NZ = 0.3
      DEFAULT_MIN_AREA_M2 = 1.0
      DEFAULT_MIN_DOT = 0.12
      PLATE_MAX_H_M = 0.3
      STRIP_LIFT_IN = 0.2
      MULLION_DEPTH_IN = 4.0
      MULLION_GAP_IN = 0.05
      PLANE_TOL_IN = 0.01
      SQ_IN_PER_M2 = ArchitectMath::INCHES_PER_M**2
      BAND_ALIGN = %w[bottom center top].freeze
      DEFAULT_BAND = { thickness_m: 0.4, depth_m: 0.2, color: '#F2EFE9', inset_m: 0.0, align: 'bottom' }.freeze

      def initialize(model, scene: nil)
        @model = model
        @scene = scene || FacadeScene.new(model)
        @definition_cache = {}
      end

      def faces(object:, camera: nil, image_w: nil, image_h: nil, min_area_m2: nil, min_dot: nil, make_unique: false)
        found = find_object(object)
        return not_found(object) if found.nil?

        ent, world_tr, path = found
        shared = instance_count(ent)
        if make_unique && shared > 1 && ent.respond_to?(:make_unique)
          ent.make_unique
          shared = instance_count(ent)
        end
        area_floor = min_area_m2.nil? ? DEFAULT_MIN_AREA_M2 : min_area_m2.to_f
        dot_floor = min_dot.nil? ? DEFAULT_MIN_DOT : min_dot.to_f
        cam = camera || view_camera
        projection = projection_for(cam, image_w, image_h)
        center = object_center_w(ent, world_tr)
        rows = []
        each_host_face(ent, world_tr) do |face, face_tr|
          info = face_info(face, face_tr, center)
          next if info.nil? || !info[:vertical] || info[:area_m2] < area_floor

          row = face_row(info, cam, projection)
          next if row.nil? || (projection && row['cam_dot'] < dot_floor)

          rows << row
        end
        rows.sort_by! { |row| row['center_px'] ? row['center_px'][0] : row['corners_m'][0][0] }
        rows.each_with_index { |row, index| row['order'] = index }
        bounds = bounds_m_of(ent, parent_tr_of(world_tr, ent))
        levels = storey_levels(bounds)
        cells = bounds ? FacadeMath.storey_cells(bounds['min'][2], bounds['max'][2], levels) : []
        {
          'ok' => true,
          'object' => name_of(ent),
          'object_path' => path,
          'shared_definition' => shared,
          'bounds_m' => bounds,
          'storeys_m' => levels,
          'storey_cells' => cells,
          'faces' => rows,
          'count' => rows.length,
          'image' => projection && { 'width' => projection[:width], 'height' => projection[:height] },
          'camera' => cam && camera_report(cam),
          'path' => model_path
        }
      end

      def place_openings(object:, items:, defaults: {}, replace: false)
        found = find_object(object)
        return not_found(object) if found.nil?

        ent, world_tr, = found
        if instance_count(ent) > 1
          return {
            'ok' => false,
            'error' => 'shared_definition',
            'message' => "#{name_of(ent)} shares its definition with other instances; call facade_faces with make_unique true first.",
            'retry' => false
          }
        end

        by_id = host_faces_by_id(ent, world_tr)
        cells = cells_for(ent, world_tr, defaults)
        plan = FacadeMath.expand_items(items, defaults, face_table(by_id, cells))
        remove_elements(ent, ROLE_OPENING, plan['items'].map { |piece| piece['face'].to_s }.uniq, nil) if replace
        results = plan['errors'].map { |row| row.merge('ok' => false) }
        resolved = []
        plan['items'].each do |piece|
          info = by_id[piece['face'].to_s]
          if info.nil?
            results << FacadeMath.failure(piece, "face #{piece['face']} is not on #{name_of(ent)}; take ids from facade_faces")
            next
          end
          spec = FacadeMath.resolve_opening(piece, face_public(info), cells)
          spec['ok'] ? resolved << spec : results << spec
        end
        occupied = replace ? [] : list(object: object, role: ROLE_OPENING)['items']
        fit = FacadeMath.reject_overlaps(resolved, occupied)
        results.concat(fit['errors'])
        fit['accepted'].each { |spec| results << place_one_opening(ent, by_id[spec['face'].to_s], spec) }
        placed = results.count { |row| row['ok'] }
        {
          'ok' => placed.positive? && results.all? { |row| row['ok'] },
          'object' => name_of(ent),
          'requested' => plan['items'].length,
          'placed' => placed,
          'failed' => results.length - placed,
          'items' => results,
          'path' => model_path
        }
      end

      def place_bands(object:, z_m:, faces: nil, thickness_m: nil, depth_m: nil, color: nil, inset_m: nil, align: nil, label: nil)
        found = find_object(object)
        return not_found(object) if found.nil?

        ent, world_tr, = found
        thickness = positive(thickness_m, DEFAULT_BAND[:thickness_m])
        depth = positive(depth_m, DEFAULT_BAND[:depth_m])
        inset = inset_m.nil? ? DEFAULT_BAND[:inset_m] : inset_m.to_f
        mode = BAND_ALIGN.include?(align.to_s) ? align.to_s : DEFAULT_BAND[:align]
        rgb = parse_color(color) || parse_color(DEFAULT_BAND[:color])
        material = material_for("MCP band #{hex_of(rgb)}", rgb)
        by_id = host_faces_by_id(ent, world_tr)
        targets = faces.nil? ? by_id.values.select { |info| info[:vertical] } : faces.map { |id| by_id[id.to_s] }
        missing = faces.nil? ? [] : faces.select { |id| by_id[id.to_s].nil? }
        rows = []
        targets.compact.each do |info|
          Array(z_m).each do |z|
            row = place_one_band(ent, info, z.to_f, thickness, depth, inset, mode, material, label)
            rows << row if row
          end
        end
        placed = rows.count { |row| row['ok'] }
        {
          'ok' => missing.empty? && placed.positive?,
          'object' => name_of(ent),
          'placed' => placed,
          'skipped' => rows.length - placed,
          'missing_faces' => missing,
          'items' => rows,
          'path' => model_path
        }
      end

      def paint(object:, faces: nil, color: nil, material: nil, texture: nil, texture_size_m: nil, clear: false)
        found = find_object(object)
        return not_found(object) if found.nil?

        ent, world_tr, = found
        targets = []
        missing = []
        if faces.nil?
          targets << ent
        else
          by_id = host_faces_by_id(ent, world_tr)
          faces.each do |id|
            info = by_id[id.to_s]
            info.nil? ? missing << id : targets << info[:face]
          end
        end
        mat = clear ? nil : paint_material(color, material, texture, texture_size_m)
        if !clear && mat.nil?
          return { 'ok' => false, 'error' => 'no_material', 'message' => 'Pass color, an existing material name, or texture.', 'retry' => false }
        end

        targets.each do |target|
          target.material = mat
          target.back_material = mat if target.respond_to?(:back_material=)
        end
        {
          'ok' => missing.empty?,
          'object' => name_of(ent),
          'painted' => targets.length,
          'material' => mat && mat.name,
          'missing_faces' => missing,
          'path' => model_path
        }
      end

      def list(object:, role: nil)
        found = find_object(object)
        return not_found(object) if found.nil?

        ent, = found
        rows = []
        each_facade_element(ent) do |element|
          row = element_row(element)
          rows << row if role.nil? || role.to_s == 'all' || row['role'] == role.to_s
        end
        {
          'ok' => true,
          'object' => name_of(ent),
          'count' => rows.length,
          'openings' => rows.count { |row| row['role'] == ROLE_OPENING },
          'bands' => rows.count { |row| row['role'] == ROLE_BAND },
          'items' => rows,
          'path' => model_path
        }
      end

      def remove(object:, role: nil, faces: nil, ids: nil)
        found = find_object(object)
        return not_found(object) if found.nil?

        ent, = found
        wanted_role = role.nil? || role.to_s == 'all' ? nil : role.to_s
        removed = remove_elements(ent, wanted_role, faces && faces.map(&:to_s), ids && ids.map(&:to_s))
        { 'ok' => true, 'object' => name_of(ent), 'removed' => removed, 'path' => model_path }
      end

      def verify(object:, items:, defaults: {}, tol_m: nil)
        found = find_object(object)
        return not_found(object) if found.nil?

        ent, world_tr, = found
        by_id = host_faces_by_id(ent, world_tr)
        cells = cells_for(ent, world_tr, defaults)
        plan = FacadeMath.expand_items(items, defaults, face_table(by_id, cells))
        expected = []
        errors = plan['errors'].dup
        plan['items'].each do |piece|
          info = by_id[piece['face'].to_s]
          if info.nil?
            errors << FacadeMath.failure(piece, "face #{piece['face']} is not on #{name_of(ent)}")
            next
          end
          spec = FacadeMath.resolve_opening(piece, face_public(info), cells)
          spec['ok'] ? expected << spec : errors << spec
        end
        fit = FacadeMath.reject_overlaps(expected)
        expected = fit['accepted']
        errors.concat(fit['errors'])
        live = list(object: object, role: ROLE_OPENING)['items']
        report = FacadeMath.diff(expected, live, tol_m: tol_m.nil? ? 0.15 : tol_m.to_f)
        report.merge(
          'ok' => report['ok'] && errors.empty?,
          'object' => name_of(ent),
          'expected' => expected.length,
          'live' => live.length,
          'schedule_errors' => errors,
          'path' => model_path
        )
      end

      private

      # ---- поиск объекта и его граней ----

      def find_object(name)
        @scene.find_object(name)
      end

      def not_found(name)
        @scene.not_found(name)
      end

      def each_host_face(ent, world_tr, &block)
        @scene.each_host_face(ent, world_tr, &block)
      end

      def each_facade_element(ent, &block)
        @scene.each_facade_element(ent, &block)
      end

      def facade_element?(ent)
        @scene.facade_element?(ent)
      end

      def name_of(ent)
        @scene.name_of(ent)
      end

      def face_id(ent)
        @scene.entity_id(ent)
      end

      def host_faces_by_id(ent, world_tr)
        center = object_center_w(ent, world_tr)
        table = {}
        each_host_face(ent, world_tr) do |face, face_tr|
          info = face_info(face, face_tr, center)
          table[info[:id].to_s] = info if info
        end
        table
      end

      def face_table(by_id, cells)
        by_id.each_with_object({}) do |(id, info), acc|
          acc[id] = { 'width_m' => info[:width_m], 'cells' => cells }
        end
      end

      def face_public(info)
        { 'width_m' => info[:width_m], 'height_m' => info[:height_m], 'z0_m' => info[:z0_m], 'z1_m' => info[:z1_m] }
      end

      # Кадр грани в мировых дюймах: внешняя нормаль, right/up, левый нижний угол, размеры в метрах.
      def face_info(face, face_tr, object_center)
        normal = transform_vector(face.normal, face_tr)
        normal = normal && FacadeMath.norm3(normal)
        return nil if normal.nil?

        verts = []
        each_vertex(face) { |position| verts << point_xyz(transform_point(position, face_tr)) }
        return nil if verts.length < 3

        center = verts.transpose.map { |axis| axis.sum / verts.length.to_f }
        flipped = false
        if object_center && dot3(normal, subtract3(center, object_center)).negative?
          normal = scale3(normal, -1.0)
          flipped = true
        end
        axes = FacadeMath.frame_axes(normal)
        return nil if axes.nil?

        right, up = axes
        us = verts.map { |v| dot3(subtract3(v, verts[0]), right) }
        vs = verts.map { |v| dot3(subtract3(v, verts[0]), up) }
        origin = add3(verts[0], add3(scale3(right, us.min), scale3(up, vs.min)))
        width_in = us.max - us.min
        height_in = vs.max - vs.min
        area_in2 = face.respond_to?(:area) ? face.area.to_f : width_in * height_in
        zs = verts.map { |v| v[2] }
        {
          face: face,
          id: face_id(face),
          face_tr: face_tr,
          normal: normal,
          right: right,
          up: up,
          origin_w: origin,
          width_m: MathN.in_to_m(width_in),
          height_m: MathN.in_to_m(height_in),
          z0_m: MathN.in_to_m(zs.min),
          z1_m: MathN.in_to_m(zs.max),
          center_w: center,
          area_m2: area_in2 / SQ_IN_PER_M2,
          vertical: normal[2].abs < VERTICAL_NZ,
          flipped: flipped
        }
      end

      def face_row(info, cam, projection)
        corners = [
          info[:origin_w],
          add3(info[:origin_w], scale3(info[:right], MathN.m_to_in(info[:width_m]))),
          add3(info[:origin_w], add3(scale3(info[:right], MathN.m_to_in(info[:width_m])), scale3(info[:up], MathN.m_to_in(info[:height_m])))),
          add3(info[:origin_w], scale3(info[:up], MathN.m_to_in(info[:height_m])))
        ]
        row = {
          'id' => info[:id],
          'width_m' => round4(info[:width_m]),
          'height_m' => round4(info[:height_m]),
          'area_m2' => round4(info[:area_m2]),
          'z0_m' => round4(info[:z0_m]),
          'z1_m' => round4(info[:z1_m]),
          'normal' => info[:normal].map { |n| n.round(4) },
          'flipped' => info[:flipped],
          'corners_m' => corners.map { |pt| pt.map { |n| round4(MathN.in_to_m(n)) } }
        }
        if cam
          to_cam = FacadeMath.norm3(subtract3(cam[:eye], info[:center_w]))
          row['cam_dot'] = to_cam ? dot3(info[:normal], to_cam).round(4) : 0.0
        end
        if projection
          quad = corners.map { |pt| FacadeMath.project(projection[:basis], cam[:eye], pt, projection[:width], projection[:height], projection[:focal]) }
          return nil if quad.any?(&:nil?)

          row['pixel_quad'] = quad.map { |xy| xy.map { |n| n.round(1) } }
          row['center_px'] = [quad.sum { |xy| xy[0] } / 4.0, quad.sum { |xy| xy[1] } / 4.0].map { |n| n.round(1) }
        end
        row
      end

      # ---- камера ----

      def view_camera
        view = @model.respond_to?(:active_view) ? @model.active_view : nil
        camera = view && view.respond_to?(:camera) ? view.camera : nil
        return nil if camera.nil?

        {
          eye: point_xyz(camera.eye),
          target: point_xyz(camera.target),
          up: point_xyz(camera.up),
          fov: camera.respond_to?(:fov) ? camera.fov.to_f : 35.0,
          fov_is_height: camera.respond_to?(:fov_is_height?) ? camera.fov_is_height? : true
        }
      rescue StandardError, ScriptError
        nil
      end

      def projection_for(cam, image_w, image_h)
        return nil if cam.nil?

        width, height = image_size(image_w, image_h)
        return nil if width.nil?

        basis = FacadeMath.camera_basis(cam[:eye], cam[:target], cam[:up])
        focal = FacadeMath.focal_px(cam[:fov], width, height, cam[:fov_is_height] != false)
        return nil if basis.nil? || focal.nil?

        { basis: basis, focal: focal, width: width, height: height }
      end

      def image_size(image_w, image_h)
        return [image_w.to_i, image_h.to_i] if image_w.to_i.positive? && image_h.to_i.positive?

        view = @model.respond_to?(:active_view) ? @model.active_view : nil
        return nil unless view && view.respond_to?(:vpwidth) && view.vpwidth.to_i.positive?

        [view.vpwidth.to_i, view.vpheight.to_i]
      end

      def camera_report(cam)
        {
          'eye_m' => cam[:eye].map { |n| round4(MathN.in_to_m(n)) },
          'target_m' => cam[:target].map { |n| round4(MathN.in_to_m(n)) },
          'up' => cam[:up].map { |n| n.round(4) },
          'fov_deg' => cam[:fov].to_f.round(3),
          'fov_is_height' => cam[:fov_is_height] != false
        }
      end

      # ---- этажи ----

      def cells_for(ent, world_tr, defaults)
        explicit = defaults.is_a?(Hash) ? (defaults['storeys_m'] || defaults[:storeys_m]) : nil
        bounds = bounds_m_of(ent, parent_tr_of(world_tr, ent))
        return [] if bounds.nil?

        levels = explicit.is_a?(Array) && !explicit.empty? ? explicit.map(&:to_f) : storey_levels(bounds)
        FacadeMath.storey_cells(bounds['min'][2], bounds['max'][2], levels)
      end

      # Отметки плит: тонкие горизонтальные контейнеры, пересекающие объект в плане и по высоте.
      def storey_levels(bounds)
        return [] if bounds.nil?

        levels = []
        collect_plates(@model.entities, identity_tr, 0) do |plate|
          next unless plate['size'][2] <= PLATE_MAX_H_M
          next unless plate['min'][0] < bounds['max'][0] && plate['max'][0] > bounds['min'][0]
          next unless plate['min'][1] < bounds['max'][1] && plate['max'][1] > bounds['min'][1]

          z = (plate['min'][2] + plate['max'][2]) / 2.0
          next unless z >= bounds['min'][2] - 0.05 && z <= bounds['max'][2] + 0.05

          levels << z.round(3)
        end
        levels.uniq.sort
      end

      def collect_plates(entities, tr, depth, &block)
        return if depth > 4

        each_entity(entities) do |ent|
          kind = classify(ent)
          next if kind.nil? || facade_element?(ent)

          box = bounds_m_of(ent, tr)
          block.call(box) if box
          collect_plates(child_entities(ent, kind), multiply_tr(tr, read_transformation(ent)), depth + 1, &block)
        end
      end

      # world_tr уже включает трансформацию самого объекта; bounds_m_of ждёт трансформацию родителя.
      def parent_tr_of(world_tr, ent)
        own = read_transformation(ent)
        return world_tr if own == :identity || world_tr == :identity
        return multiply_tr(world_tr, own.inverse) if own.respond_to?(:inverse)

        world_tr
      end

      def object_center_w(ent, world_tr)
        box = bounds_m_of(ent, parent_tr_of(world_tr, ent))
        return nil if box.nil?

        [(box['min'][0] + box['max'][0]) / 2.0, (box['min'][1] + box['max'][1]) / 2.0, (box['min'][2] + box['max'][2]) / 2.0]
          .map { |n| MathN.m_to_in(n) }
      end

      # ---- проёмы ----

      def place_one_opening(ent, info, spec)
        host = host_entities_of(info[:face])
        scale = axis_scale(info[:face_tr])
        local = local_frame(info, spec['u0_m'], spec['v0_m'])
        definition = opening_definition(spec, scale)
        transformation = axes_transformation(local[:origin], local[:right], local[:up], local[:normal])
        instance = host.add_instance(definition, transformation)
        glued = glue(instance, info[:face])
        label = spec['label'].to_s.empty? ? "#{spec['kind']} s#{spec['storey']}" : spec['label']
        instance.name = label if instance.respond_to?(:name=)
        write_attributes(instance, ROLE_OPENING, name_of(ent), info[:id], spec.merge('label' => label))
        {
          'ok' => true,
          'id' => face_id(instance),
          'face' => info[:id],
          'kind' => spec['kind'],
          'u0_m' => spec['u0_m'],
          'width_m' => spec['width_m'],
          'z0_m' => spec['z0_m'],
          'z1_m' => spec['z1_m'],
          'storey' => spec['storey'],
          'glued' => glued,
          'label' => label,
          'item' => spec['item'],
          'column' => spec['column']
        }
      rescue StandardError, ScriptError => error
        FacadeMath.failure(spec, "#{error.class}: #{error.message}")
      end

      # Определение проёма в локальных дюймах: X вправо, Y вверх, Z наружу. Контур на z=0 режет стену.
      def opening_definition(spec, scale)
        w = MathN.m_to_in(spec['width_m']) / scale
        h = MathN.m_to_in(spec['height_m']) / scale
        recess = MathN.m_to_in(spec['recess_m']) / scale
        frame_w = MathN.m_to_in(spec['frame_w_m']) / scale
        frame_out = [MathN.m_to_in(spec['frame_out_m']) / scale, STRIP_LIFT_IN * 2].max
        mullion_w = MathN.m_to_in(spec['mullion_w_m']) / scale
        frame_rgb = parse_color(spec['frame_color']) || parse_color(FacadeMath::OPENING_DEFAULTS['frame_color'])
        glass_rgb = parse_color(spec['glass_color']) || parse_color(FacadeMath::OPENING_DEFAULTS['glass_color'])
        key = [
          spec['kind'], w.round(2), h.round(2), recess.round(2), frame_w.round(2), frame_out.round(2),
          spec['frame_edges'].sort.join(','), spec['mullions'], spec['transom'], hex_of(frame_rgb), hex_of(glass_rgb)
        ].join('|')
        cached = @definition_cache[key] || find_definition(key)
        return cached if cached

        definition = @model.definitions.add("MCP opening #{spec['kind']} #{spec['width_m'].round(2)}x#{spec['height_m'].round(2)}")
        build_opening_geometry(definition.entities, w, h, recess, frame_w, frame_out, mullion_w, spec, frame_rgb, glass_rgb)
        behavior = definition.behavior
        behavior.is2d = true
        behavior.cuts_opening = true
        behavior.snapto = snap_arbitrary if behavior.respond_to?(:snapto=)
        definition.set_attribute(DICT, 'key', key)
        definition.set_attribute(DICT, 'role', 'opening_definition')
        @definition_cache[key] = definition
      end

      def find_definition(key)
        return nil unless @model.respond_to?(:definitions)

        @model.definitions.each do |definition|
          next unless definition.respond_to?(:get_attribute)
          return definition if definition.get_attribute(DICT, 'key') == key
        end
        nil
      end

      def build_opening_geometry(ents, w, h, recess, frame_w, frame_out, mullion_w, spec, frame_rgb, glass_rgb)
        frame_material = material_for("MCP frame #{hex_of(frame_rgb)}", frame_rgb)
        glass_material = material_for("MCP glass #{hex_of(glass_rgb)}", glass_rgb)
        recess_pane(ents, w, h, recess)
        edges = spec['frame_edges']
        y_low = edges.include?('bottom') ? -frame_w : 0.0
        y_high = edges.include?('top') ? h + frame_w : h
        extrude(ents, add_rect(ents, -frame_w, y_low, 0.0, y_high, STRIP_LIFT_IN), frame_out - STRIP_LIFT_IN) if edges.include?('left')
        extrude(ents, add_rect(ents, w, y_low, w + frame_w, y_high, STRIP_LIFT_IN), frame_out - STRIP_LIFT_IN) if edges.include?('right')
        extrude(ents, add_rect(ents, 0.0, -frame_w, w, 0.0, STRIP_LIFT_IN), frame_out - STRIP_LIFT_IN) if edges.include?('bottom')
        extrude(ents, add_rect(ents, 0.0, h, w, h + frame_w, STRIP_LIFT_IN), frame_out - STRIP_LIFT_IN) if edges.include?('top')
        bar_z = -recess + MULLION_GAP_IN
        spec['mullions'].to_i.times do |index|
          x = (index + 1) * w / (spec['mullions'].to_i + 1).to_f
          extrude(ents, add_rect(ents, x - (mullion_w / 2.0), 0.0, x + (mullion_w / 2.0), h, bar_z), MULLION_DEPTH_IN)
        end
        if spec['transom']
          y = h * 0.72
          extrude(ents, add_rect(ents, 0.0, y - (mullion_w / 2.0), w, y + (mullion_w / 2.0), bar_z), MULLION_DEPTH_IN)
        end
        each_entity(ents) do |item|
          next unless face?(item)

          material = pane_face?(item, recess) ? glass_material : frame_material
          item.material = material
          item.back_material = material if item.respond_to?(:back_material=)
        end
      end

      # Стекло утоплено в стену: контур на z=0 остаётся и режет стену, дальняя грань смотрит наружу.
      def recess_pane(ents, w, h, recess)
        extrude(ents, add_rect(ents, 0.0, 0.0, w, h, 0.0), -recess)
        each_entity(ents) do |item|
          next unless face?(item) && pane_face?(item, recess)

          normal = vector_xyz(item.normal)
          item.reverse! if normal && normal[2].negative?
        end
      end

      # pushpull оставляет грань на стартовой плоскости (при отрицательном ходе исходную, при положительном
      # копию); вплотную к стене она мерцала бы, а на проёме закрывала бы стекло. После выдавливания
      # стираем всё, что лежит целиком в стартовой плоскости; рёбра контура остаются у боковых граней.
      def extrude(ents, face, distance)
        anchor = first_vertex(face)
        origin = anchor && point_xyz(anchor)
        normal = vector_xyz(face.normal)
        face.pushpull(distance)
        return if origin.nil? || normal.nil?

        leftovers = []
        each_entity(ents) do |item|
          next unless face?(item) && (!item.respond_to?(:valid?) || item.valid?)

          leftovers << item if in_plane?(item, origin, normal)
        end
        leftovers.each { |item| item.erase! if item.respond_to?(:erase!) }
      end

      def in_plane?(face, origin, normal)
        seen = false
        each_vertex(face) do |position|
          seen = true
          return false if dot3(subtract3(point_xyz(position), origin), normal).abs > PLANE_TOL_IN
        end
        seen
      end

      def pane_face?(face, recess)
        zs = []
        each_vertex(face) { |position| zs << coord(position, 2) }
        !zs.empty? && zs.all? { |z| (z + recess).abs < 1.0e-3 }
      end

      def add_rect(ents, x0, y0, x1, y1, z)
        face = ents.add_face(point(x0, y0, z), point(x1, y0, z), point(x1, y1, z), point(x0, y1, z))
        raise 'add_face returned nil' if face.nil?

        normal = vector_xyz(face.normal)
        face.reverse! if normal && normal[2].negative?
        face
      end

      def snap_arbitrary
        Object.const_defined?(:SnapTo_Arbitrary) ? Object.const_get(:SnapTo_Arbitrary) : 0
      end

      def glue(instance, face)
        return false unless instance.respond_to?(:glued_to=)

        instance.glued_to = face
        true
      rescue StandardError, ScriptError
        false
      end

      # ---- пояса ----

      def place_one_band(ent, info, z, thickness, depth, inset, mode, material, label)
        bottom = case mode
                 when 'center' then z - (thickness / 2.0)
                 when 'top' then z - thickness
                 else z
                 end
        v0 = [bottom - info[:z0_m], 0.0].max
        v1 = [bottom + thickness - info[:z0_m], info[:height_m]].min
        return nil if v1 - v0 < 0.02

        u0 = inset
        u1 = info[:width_m] - inset
        return nil if u1 - u0 < 0.05

        host = host_entities_of(info[:face])
        scale = axis_scale(info[:face_tr])
        local = local_frame(info, u0, v0)
        group = host.add_group
        corners = [
          local[:origin],
          offset_point(local[:origin], local[:right], local[:up], MathN.m_to_in(u1 - u0) / scale, 0.0),
          offset_point(local[:origin], local[:right], local[:up], MathN.m_to_in(u1 - u0) / scale, MathN.m_to_in(v1 - v0) / scale),
          offset_point(local[:origin], local[:right], local[:up], 0.0, MathN.m_to_in(v1 - v0) / scale)
        ]
        face = group.entities.add_face(*corners)
        raise 'add_face returned nil' if face.nil?

        normal = vector_xyz(face.normal)
        face.reverse! if normal && dot3(normal, local[:normal]).negative?
        extrude(group.entities, face, MathN.m_to_in(depth) / scale)
        group.material = material
        each_entity(group.entities) do |item|
          next unless face?(item)

          item.material = material
          item.back_material = material if item.respond_to?(:back_material=)
        end
        name = label.to_s.empty? ? "band z#{z.round(2)}" : label.to_s
        group.name = name if group.respond_to?(:name=)
        write_attributes(group, ROLE_BAND, name_of(ent), info[:id], 'z0_m' => (info[:z0_m] + v0).round(4), 'z1_m' => (info[:z0_m] + v1).round(4), 'depth_m' => depth, 'label' => name)
        {
          'ok' => true,
          'id' => face_id(group),
          'face' => info[:id],
          'z0_m' => (info[:z0_m] + v0).round(4),
          'z1_m' => (info[:z0_m] + v1).round(4),
          'label' => name
        }
      rescue StandardError, ScriptError => error
        { 'ok' => false, 'face' => info[:id], 'z_m' => z, 'error' => "#{error.class}: #{error.message}" }
      end

      # ---- локальные координаты хоста ----

      def host_entities_of(face)
        parent = face.parent
        return parent.entities if parent.respond_to?(:entities)
        return parent if parent.respond_to?(:add_instance) || parent.respond_to?(:add_group)

        parent
      end

      def axis_scale(tr)
        return 1.0 if tr.nil? || tr == :identity || !defined?(Geom::Vector3d)

        vec = transform_vector(Geom::Vector3d.new(1, 0, 0), tr)
        length = vec ? length3(vec) : 1.0
        length.positive? ? length : 1.0
      end

      # Кадр грани, перенесённый в координаты её контейнера: точка (u0, v0) в метрах от левого нижнего угла.
      def local_frame(info, u0_m, v0_m)
        origin_w = add3(info[:origin_w], add3(scale3(info[:right], MathN.m_to_in(u0_m)), scale3(info[:up], MathN.m_to_in(v0_m))))
        inverse = inverse_of(info[:face_tr])
        {
          origin: to_point(transform_point(point(*origin_w), inverse)),
          right: local_vector(info[:right], inverse),
          up: local_vector(info[:up], inverse),
          normal: local_vector(info[:normal], inverse)
        }
      end

      def inverse_of(tr)
        return :identity if tr.nil? || tr == :identity
        return tr.inverse if tr.respond_to?(:inverse)

        :identity
      end

      def local_vector(world_vec, inverse)
        return world_vec if inverse == :identity || !defined?(Geom::Vector3d)

        moved = transform_vector(Geom::Vector3d.new(*world_vec), inverse)
        FacadeMath.norm3(moved) || world_vec
      end

      def to_point(pt)
        pt.respond_to?(:x) ? pt : point(*pt)
      end

      def axes_transformation(origin, right, up, normal)
        if defined?(Geom::Transformation) && Geom::Transformation.respond_to?(:axes)
          return Geom::Transformation.axes(origin, vector(right), vector(up), vector(normal))
        end

        { origin: point_xyz(origin), right: right, up: up, normal: normal }
      end

      def vector(xyz)
        defined?(Geom::Vector3d) ? Geom::Vector3d.new(*xyz) : xyz
      end

      # ---- материалы ----

      def paint_material(color, material_name, texture, texture_size_m)
        if material_name && @model.materials[material_name.to_s]
          return @model.materials[material_name.to_s]
        end

        rgb = parse_color(color)
        if texture
          name = material_name.to_s.empty? ? "MCP texture #{File.basename(texture.to_s, '.*')}" : material_name.to_s
          material = @model.materials[name] || @model.materials.add(name)
          material.texture = texture.to_s
          if texture_size_m.to_f.positive? && material.respond_to?(:texture) && material.texture.respond_to?(:size=)
            material.texture.size = MathN.m_to_in(texture_size_m)
          end
          material.color = Sketchup::Color.new(rgb[0], rgb[1], rgb[2]) if rgb && defined?(Sketchup::Color)
          return material
        end
        return nil if rgb.nil?

        material_for(material_name.to_s.empty? ? "MCP paint #{hex_of(rgb)}" : material_name.to_s, rgb)
      end

      # ---- элементы фасада ----

      def element_row(element)
        row = { 'id' => face_id(element), 'name' => name_of(element) }
        %w[role object face kind u0_m width_m z0_m z1_m storey frame_edges label depth_m item column].each do |key|
          value = element.get_attribute(DICT, key)
          row[key] = value unless value.nil?
        end
        row['face'] = row['face'].to_s if row.key?('face')
        row['hidden'] = element.hidden? if element.respond_to?(:hidden?)
        if element.respond_to?(:glued_to)
          glued = element.glued_to
          row['glued'] = !glued.nil?
        end
        row
      end

      def remove_elements(ent, role, face_ids, ids)
        doomed = []
        each_facade_element(ent) do |element|
          next if role && element.get_attribute(DICT, 'role').to_s != role
          next if face_ids && !face_ids.include?(element.get_attribute(DICT, 'face').to_s)
          next if ids && !ids.include?(face_id(element).to_s)

          doomed << element
        end
        doomed.each { |element| element.erase! if element.respond_to?(:erase!) }
        doomed.length
      end

      def write_attributes(element, role, object_name, face_id, spec)
        element.set_attribute(DICT, 'role', role)
        element.set_attribute(DICT, 'object', object_name)
        element.set_attribute(DICT, 'face', face_id.to_s)
        %w[kind u0_m width_m z0_m z1_m storey label depth_m item column].each do |key|
          element.set_attribute(DICT, key, spec[key]) if spec.key?(key) && !spec[key].nil?
        end
        element.set_attribute(DICT, 'frame_edges', Array(spec['frame_edges']).map(&:to_s)) if spec['frame_edges']
      end

      def instance_count(ent)
        return 1 unless ent.respond_to?(:definition)

        definition = ent.definition
        return definition.count_instances if definition.respond_to?(:count_instances)
        return definition.instances.length if definition.respond_to?(:instances)

        1
      end

      def positive(value, default)
        n = value.to_f
        n.positive? ? n : default
      end
    end
  end
end
