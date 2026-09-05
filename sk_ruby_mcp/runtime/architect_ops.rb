# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Геометрия масс и проёмов в метрах. Один вызов = одна операция undo снаружи.
    class ArchitectOps
      MathN = ArchitectMath
      DEFAULT_STOREY_H_M = 3.3
      LIST_MAX_ITEMS = 120
      LIST_MAX_DEPTH = 8
      VERTICAL_DOT = 0.25
      FACING_DOT = 0.75

      def initialize(model)
        @model = model
      end

      def place_box(origin_m:, size_m:, name:, tag:, color:, storeys:)
        origin = origin_m
        size = size_m
        floors = storeys.nil? ? 1 : storeys.to_i
        floors = 1 if floors < 1
        parent = @model.active_entities.add_group
        parent.name = name.to_s.empty? ? 'Box' : name.to_s
        apply_tag(parent, tag)
        z0 = MathN.m_to_in(origin[2])
        height_each = size[2] / floors.to_f
        created = []
        index = 0
        while index < floors
          target = floors == 1 ? parent : parent.entities.add_group
          if floors > 1
            target.name = format('Этаж %02d', index + 1)
            apply_tag(target, tag)
          end
          origin_z = origin[2] + (index * height_each)
          add_solid_box(target, [origin[0], origin[1], origin_z], [size[0], size[1], height_each])
          created << target.name
          index += 1
        end
        apply_color(parent, color)
        {
          'ok' => true,
          'name' => parent.name,
          'storeys' => floors,
          'storey_names' => created,
          'origin_m' => origin,
          'size_m' => size,
          'tag' => tag,
          'bounds_m' => bounds_m_of(parent, identity_tr),
          'path' => model_path
        }
      end

      def list_groups(max_depth:, max_items:)
        depth_cap = clamp_int(max_depth, 1, 16, LIST_MAX_DEPTH)
        item_cap = clamp_int(max_items, 1, 400, LIST_MAX_ITEMS)
        acc = []
        truncated = false
        walk_containers(@model.entities, 0, '', identity_tr, acc, depth_cap, item_cap) do
          truncated = true
        end
        {
          'ok' => true,
          'count' => acc.length,
          'truncated' => truncated,
          'groups' => acc,
          'path' => model_path
        }
      end

      def site_metrics(site_w_m:, site_d_m:, site_area_m2:, storey_h_m:, min_height_m:)
        storey = storey_h_m.nil? ? DEFAULT_STOREY_H_M : storey_h_m.to_f
        storey = DEFAULT_STOREY_H_M if storey <= 0.0
        min_h = min_height_m.nil? ? 1.0 : min_height_m.to_f
        min_h = 1.0 if min_h < 0.0
        listed = list_groups(max_depth: 1, max_items: LIST_MAX_ITEMS)
        top = listed['groups'].select { |row| row['depth'].to_i.zero? }
        groups_footprint = 0.0
        gfa = 0.0
        rows = top.map do |row|
          size = row['size_m'] || [0.0, 0.0, 0.0]
          height = size[2].to_f
          next if height < min_h

          footprint = MathN.footprint_m2(size)
          floors = MathN.storeys_guess(height, storey)
          piece_gfa = footprint * floors
          groups_footprint += footprint
          gfa += piece_gfa
          {
            'name' => row['name'],
            'footprint_m2' => round4(footprint),
            'height_m' => round4(height),
            'storeys_guess' => floors,
            'gfa_m2' => round4(piece_gfa)
          }
        end.compact
        outer = outer_footprint_m2
        site_area = site_area_from(site_w_m, site_d_m, site_area_m2)
        payload = {
          'ok' => true,
          'storey_h_m' => storey,
          'min_height_m' => round4(min_h),
          'site_w_m' => site_w_m,
          'site_d_m' => site_d_m,
          'site_area_m2' => site_area && round4(site_area),
          'groups_footprint_m2' => round4(groups_footprint),
          'outer_footprint_m2' => outer && round4(outer),
          'coverage_groups' => coverage(groups_footprint, site_area),
          'coverage_outer' => coverage(outer, site_area),
          'gfa_m2' => round4(gfa),
          'groups' => rows,
          'path' => model_path
        }
        if !outer.nil? && groups_footprint > (outer * 1.02)
          payload['overlap_warning'] = true
          payload['message'] =
            'groups_footprint_m2 sums axis-aligned boxes and can exceed the outer rectangle when masses overlap at corners. For a courtyard ring the building footprint is site minus courtyard, not four full-length boxes.'
        end
        payload
      end

      def place_perimeter(origin_m:, site_w_m:, site_d_m:, depth_m:, height_m:, names:, tag:, color:, storeys:)
        plan = MathN.perimeter_plan(site_w: site_w_m, site_d: site_d_m, depth: depth_m, origin: origin_m)
        unless plan['ok']
          return {
            'ok' => false,
            'error' => plan['error'],
            'message' => plan['message'],
            'retry' => false
          }
        end

        floors = storeys.nil? ? 1 : storeys.to_i
        floors = 1 if floors < 1
        created = []
        plan['wings'].each do |wing|
          facing = wing['facing']
          name = names[facing] || default_wing_name(facing)
          xy = wing['size_xy_m']
          origin = wing['origin_m']
          box = place_box(
            origin_m: origin,
            size_m: [xy[0], xy[1], height_m],
            name: name,
            tag: tag,
            color: color,
            storeys: floors
          )
          created << {
            'facing' => facing,
            'name' => box['name'],
            'origin_m' => box['origin_m'],
            'size_m' => box['size_m'],
            'bounds_m' => box['bounds_m']
          }
        end
        site_area = plan['site_m2']
        {
          'ok' => true,
          'count' => created.length,
          'wings' => created,
          'courtyard_m' => plan['courtyard_m'].map { |n| round4(n) },
          'courtyard_m2' => round4(plan['courtyard_m2']),
          'footprint_m2' => round4(plan['footprint_m2']),
          'site_w_m' => site_w_m.to_f,
          'site_d_m' => site_d_m.to_f,
          'site_area_m2' => round4(site_area),
          'coverage' => coverage(plan['footprint_m2'], site_area),
          'depth_m' => depth_m.to_f,
          'height_m' => height_m.to_f,
          'storeys' => floors,
          'path' => model_path
        }
      end

      def grid_openings(group_name:, facing:, cols:, rows:, width_m:, height_m:, sill_m:, margin_m:)
        direction = MathN.facing_vector(facing)
        raise ArgumentError, 'facing must be north, south, east or west' if direction.nil?

        found = find_named_group(@model.entities, group_name.to_s, identity_tr)
        if found.nil?
          names = []
          walk_containers(@model.entities, 0, '', identity_tr, names, 6, 40) {}
          available = names.map { |row| row['path'] }.first(20)
          return {
            'ok' => false,
            'error' => 'group_not_found',
            'message' => "No group named #{group_name.inspect}. Available: #{available.join(', ')}",
            'retry' => true
          }
        end

        group, world_tr = found
        face_hit = largest_facing_face(group, world_tr, direction)
        if face_hit.nil?
          return {
            'ok' => false,
            'error' => 'face_not_found',
            'message' => "No vertical #{facing} façade on #{group_name}",
            'retry' => true
          }
        end

        face, _face_tr, face_w, face_h = face_hit
        layout = MathN.grid_slots(
          face_w: face_w,
          face_h: face_h,
          cols: cols,
          rows: rows,
          win_w: width_m,
          win_h: height_m,
          sill: sill_m,
          margin: margin_m
        )
        unless layout['ok']
          return {
            'ok' => false,
            'error' => layout['error'],
            'message' => layout['message'],
            'retry' => false
          }
        end

        placed = 0
        skipped = 0
        @last_punch_error = nil
        face = face_hit[0]
        layout['slots'].each do |slot|
          unless alive?(face)
            @last_punch_error ||= 'face vanished'
            skipped += 1
            next
          end
          if punch_slot(face, slot)
            placed += 1
          else
            skipped += 1
          end
        end
        first = layout['slots'].first
        last = layout['slots'].last
        payload = {
          'ok' => true,
          'group' => group.name,
          'facing' => facing.to_s.strip.downcase,
          'requested' => layout['slots'].length,
          'placed' => placed,
          'skipped' => skipped,
          'face_width_m' => round4(face_w),
          'face_height_m' => round4(face_h),
          'gap_u_m' => round4(layout['gap_u']),
          'gap_v_m' => round4(layout['gap_v']),
          'first_sill_m' => first && round4(first['v']),
          'last_head_m' => last && round4(last['v'] + last['h']),
          'path' => model_path
        }
        payload['skip_error'] = @last_punch_error if placed.zero? && @last_punch_error
        payload
      end

      private

      def add_solid_box(group, origin_m, size_m)
        ox = MathN.m_to_in(origin_m[0])
        oy = MathN.m_to_in(origin_m[1])
        oz = MathN.m_to_in(origin_m[2])
        dx = MathN.m_to_in(size_m[0])
        dy = MathN.m_to_in(size_m[1])
        dz = MathN.m_to_in(size_m[2])
        pts = [
          point(ox, oy, oz),
          point(ox + dx, oy, oz),
          point(ox + dx, oy + dy, oz),
          point(ox, oy + dy, oz)
        ]
        face = group.entities.add_face(pts)
        raise 'add_face returned nil' if face.nil?

        normal = face.normal
        face.reverse! if normal.respond_to?(:z) && normal.z < 0
        face.pushpull(dz)
        face
      end

      def default_wing_name(facing)
        {
          'south' => 'South wing',
          'north' => 'North wing',
          'east' => 'East wing',
          'west' => 'West wing'
        }[facing.to_s] || facing.to_s
      end

      def apply_tag(entity, tag)
        return if tag.to_s.empty?

        layer = nil
        layer = @model.layers[tag] if @model.layers.respond_to?(:[])
        layer = @model.layers.add(tag) if layer.nil?
        entity.layer = layer if layer
      end

      def apply_color(entity, color)
        rgb = parse_color(color)
        return if rgb.nil?

        if defined?(Sketchup) && defined?(Sketchup::Color) && @model.respond_to?(:materials)
          base = entity.name.to_s.empty? ? 'MCP color' : "MCP #{entity.name}"
          material = unique_material(base)
          material.color = Sketchup::Color.new(rgb[0], rgb[1], rgb[2])
          entity.material = material
        else
          entity.material = rgb
        end
      end

      def unique_material(base)
        name = base
        index = 2
        while @model.materials[name]
          name = "#{base} #{index}"
          index += 1
        end
        @model.materials.add(name)
      end

      def parse_color(color)
        return nil if color.nil?

        if color.is_a?(Array) && color.size == 3 && color.all? { |n| n.is_a?(Numeric) }
          return color.map { |n| n.to_i.clamp(0, 255) }
        end
        if color.is_a?(String)
          hex = MathN.parse_hex_color(color)
          return hex if hex

          parts = color.split(/[,\s]+/).reject(&:empty?)
          if parts.size == 3 && parts.all? { |part| part =~ /\A\d+\z/ }
            return parts.map { |part| part.to_i.clamp(0, 255) }
          end
        end
        nil
      end

      def walk_containers(entities, depth, path, tr, acc, max_depth, max_items)
        return if depth > max_depth

        each_entity(entities) do |ent|
          if acc.length >= max_items
            yield
            return
          end
          kind = classify(ent)
          next if kind.nil?

          child_ents = child_entities(ent, kind)
          child_tr = multiply_tr(tr, read_transformation(ent))
          name = ent.respond_to?(:name) ? ent.name.to_s : ''
          node_path = if path.empty?
                        name.empty? ? '(unnamed)' : name
                      else
                        "#{path}/#{name.empty? ? '(unnamed)' : name}"
                      end
          box = bounds_m_of(ent, tr)
          acc << {
            'name' => name,
            'path' => node_path,
            'kind' => kind,
            'depth' => depth,
            'tag' => tag_name(ent),
            'faces' => count_direct_faces(child_ents),
            'bounds_m' => box,
            'size_m' => box && box['size']
          }
          walk_containers(child_ents, depth + 1, node_path, child_tr, acc, max_depth, max_items)
        end
      end

      def find_named_group(entities, name, tr)
        wanted = name.to_s
        wanted_down = wanted.downcase
        exact = nil
        ci_match = nil
        sub = nil
        search_named(entities, tr) do |group, world_tr|
          current = group.respond_to?(:name) ? group.name.to_s : ''
          exact ||= [group, world_tr] if current == wanted
          ci_match ||= [group, world_tr] if exact.nil? && current.downcase == wanted_down
          sub ||= [group, world_tr] if exact.nil? && !current.empty? && current.downcase.include?(wanted_down)
        end
        exact || ci_match || sub
      end

      def search_named(entities, tr, &block)
        each_entity(entities) do |ent|
          kind = classify(ent)
          next if kind.nil?

          child_tr = multiply_tr(tr, read_transformation(ent))
          block.call(ent, child_tr) if kind == 'group'
          search_named(child_entities(ent, kind), child_tr, &block)
        end
      end

      def largest_facing_face(group, world_tr, direction)
        best = nil
        best_area = 0.0
        visit_faces(group, world_tr) do |face, face_world|
          next unless face.respond_to?(:normal)

          normal = transform_vector(face.normal, face_world)
          next if normal.nil?
          next if normal[2].abs > VERTICAL_DOT

          dot = (normal[0] * direction[0]) + (normal[1] * direction[1])
          next if dot < FACING_DOT

          width_m, height_m, area = face_span_m(face)
          next if area <= best_area

          best = [face, face_world, width_m, height_m]
          best_area = area
        end
        best
      end

      def visit_faces(container, world_tr, &block)
        ents = container.respond_to?(:entities) ? container.entities : container
        each_entity(ents) do |ent|
          if face?(ent)
            block.call(ent, world_tr)
            next
          end
          kind = classify(ent)
          next if kind.nil?

          child_tr = multiply_tr(world_tr, read_transformation(ent))
          visit_faces(ent, child_tr, &block)
        end
      end

      def face_span_m(face)
        frame = face_frame(face)
        return [0.0, 0.0, 0.0] if frame.nil?

        [frame[:width_m], frame[:height_m], frame[:width_m] * frame[:height_m]]
      end

      def face_frame(face)
        origin, right, up = face_axes(face)
        return nil if origin.nil?

        us = []
        vs = []
        each_vertex(face) do |position|
          vec = subtract_points(position, origin)
          us << dot3(vec, right)
          vs << dot3(vec, up)
        end
        return nil if us.empty?

        {
          origin: origin,
          right: right,
          up: up,
          u_min: us.min,
          v_min: vs.min,
          width_m: MathN.in_to_m(us.max - us.min),
          height_m: MathN.in_to_m(vs.max - vs.min)
        }
      end

      def punch_slot(face, slot)
        frame = face_frame(face)
        return false if frame.nil?

        u0, v0, u1, v1 = MathN.slot_uv_in(frame[:u_min], frame[:v_min], slot)
        corners = [
          offset_point(frame[:origin], frame[:right], frame[:up], u0, v0),
          offset_point(frame[:origin], frame[:right], frame[:up], u1, v0),
          offset_point(frame[:origin], frame[:right], frame[:up], u1, v1),
          offset_point(frame[:origin], frame[:right], frame[:up], u0, v1)
        ]
        corners = project_to_face(face, corners)
        ents = entities_of_face(face)
        inner = add_face_any(ents, corners)
        if inner.nil?
          @last_punch_error ||= 'add_face returned nil'
          return false
        end
        if same_entity?(inner, face)
          @last_punch_error = 'add_face returned the wall face'
          return false
        end
        inner.erase! if inner.respond_to?(:erase!) && (!inner.respond_to?(:valid?) || inner.valid?)
        true
      rescue StandardError, ScriptError => error
        @last_punch_error = "#{error.class}: #{error.message}"
        false
      end

      def add_face_any(ents, corners)
        inner = ents.add_face(*Array(corners))
        return inner unless inner.nil?

        ents.add_face(*Array(corners).reverse)
      rescue StandardError, ScriptError => error
        @last_punch_error = "#{error.class}: #{error.message}"
        nil
      end

      def entities_of_face(face)
        parent = face.parent
        return parent if parent.respond_to?(:add_face)
        return parent.entities if parent.respond_to?(:entities)

        parent
      end

      def same_entity?(left, right)
        left.equal?(right) || (left.respond_to?(:entityID) && right.respond_to?(:entityID) && left.entityID == right.entityID)
      end

      def face_axes(face)
        return nil unless face.respond_to?(:normal) && face.respond_to?(:vertices)

        normal = vector_xyz(face.normal)
        return nil if normal.nil?

        first = first_vertex(face)
        return nil if first.nil?

        up = [0.0, 0.0, 1.0]
        proj = scale3(normal, dot3(up, normal))
        up = subtract3(up, proj)
        if length3(up) < 1.0e-8
          up = [1.0, 0.0, 0.0]
          proj = scale3(normal, dot3(up, normal))
          up = subtract3(up, proj)
        end
        up = normalize3(up)
        return nil if up.nil?

        # Снаружи: right = up × normal, чтобы слева направо смотреть на фасад.
        right = normalize3(cross3(up, normal))
        return nil if right.nil?

        [first, right, up]
      end

      def project_to_face(face, points)
        return points unless face.respond_to?(:plane)

        points.map do |pt|
          if pt.respond_to?(:project_to_plane)
            pt.project_to_plane(face.plane)
          else
            pt
          end
        end
      end

      def bounds_m_of(entity, parent_tr)
        return nil unless entity.respond_to?(:bounds)

        bounds = entity.bounds
        return nil if bounds.nil?

        corners = (0..7).map { |index| corner_point(bounds, index) }
        corners.compact!
        return nil if corners.empty?

        world = corners.map { |pt| transform_point(pt, parent_tr) }
        xs = world.map { |pt| coord(pt, 0) }
        ys = world.map { |pt| coord(pt, 1) }
        zs = world.map { |pt| coord(pt, 2) }
        min = [MathN.in_to_m(xs.min), MathN.in_to_m(ys.min), MathN.in_to_m(zs.min)]
        max = [MathN.in_to_m(xs.max), MathN.in_to_m(ys.max), MathN.in_to_m(zs.max)]
        {
          'min' => min.map { |n| round4(n) },
          'max' => max.map { |n| round4(n) },
          'size' => [max[0] - min[0], max[1] - min[1], max[2] - min[2]].map { |n| round4(n) }
        }
      rescue StandardError, ScriptError
        nil
      end

      def outer_footprint_m2
        return nil unless @model.respond_to?(:bounds)

        box = bounds_m_of(OpenStructBounds.new(@model.bounds), identity_tr)
        return nil if box.nil? || box['size'].nil?

        MathN.footprint_m2(box['size'])
      rescue StandardError, ScriptError
        nil
      end

      def site_area_from(width, depth, area)
        return area.to_f if area.is_a?(Numeric) && area.to_f.positive?
        return width.to_f * depth.to_f if width.is_a?(Numeric) && depth.is_a?(Numeric) && width.to_f.positive? && depth.to_f.positive?

        nil
      end

      def coverage(footprint, site_area)
        return nil if footprint.nil? || site_area.nil? || site_area.to_f <= 0.0

        round4(footprint.to_f / site_area.to_f)
      end

      def classify(ent)
        return nil if ent.respond_to?(:deleted?) && ent.deleted?
        if defined?(Sketchup)
          return 'group' if defined?(Sketchup::Group) && ent.is_a?(Sketchup::Group)
          return 'instance' if defined?(Sketchup::ComponentInstance) && ent.is_a?(Sketchup::ComponentInstance)
        end
        return 'group' if ent.respond_to?(:entities) && ent.respond_to?(:transformation) && !ent.respond_to?(:definition)
        return 'instance' if ent.respond_to?(:definition) && ent.respond_to?(:transformation)

        nil
      end

      def face?(ent)
        return true if defined?(Sketchup) && defined?(Sketchup::Face) && ent.is_a?(Sketchup::Face)

        ent.respond_to?(:vertices) && ent.respond_to?(:normal) && !ent.respond_to?(:entities)
      end

      def child_entities(ent, kind)
        if kind == 'instance' && ent.respond_to?(:definition)
          ent.definition.entities
        else
          ent.entities
        end
      end

      def each_entity(entities, &block)
        return if entities.nil?

        list = if entities.respond_to?(:to_a)
                 entities.to_a
               elsif entities.respond_to?(:items)
                 entities.items.dup
               else
                 []
               end
        list.each do |ent|
          next unless alive?(ent)

          block.call(ent)
        end
      end

      def alive?(ent)
        return false if ent.nil?
        return false if ent.respond_to?(:deleted?) && ent.deleted?
        return false if ent.respond_to?(:valid?) && !ent.valid?

        true
      end

      def count_direct_faces(entities)
        n = 0
        each_entity(entities) { |ent| n += 1 if face?(ent) }
        n
      end

      def tag_name(ent)
        return nil unless ent.respond_to?(:layer)

        layer = ent.layer
        layer.respond_to?(:name) ? layer.name.to_s : layer.to_s
      rescue StandardError, ScriptError
        nil
      end

      def read_transformation(ent)
        ent.respond_to?(:transformation) ? ent.transformation : identity_tr
      end

      def identity_tr
        if defined?(Geom) && defined?(Geom::Transformation)
          Geom::Transformation.new
        else
          :identity
        end
      end

      def multiply_tr(left, right)
        return right if left.nil? || left == :identity
        return left if right.nil? || right == :identity
        return left * right if left.respond_to?(:*)

        left
      end

      def transform_point(pt, tr)
        return pt if tr.nil? || tr == :identity || !pt.respond_to?(:transform)

        pt.transform(tr)
      rescue StandardError, ScriptError
        pt
      end

      def transform_vector(vec, tr)
        xyz = vector_xyz(vec)
        return xyz if xyz.nil?
        return xyz if tr.nil? || tr == :identity || !vec.respond_to?(:transform)

        transformed = vec.transform(tr)
        vector_xyz(transformed)
      rescue StandardError, ScriptError
        xyz
      end

      def point(x, y, z)
        if defined?(Geom) && defined?(Geom::Point3d)
          Geom::Point3d.new(x, y, z)
        else
          [x, y, z]
        end
      end

      def corner_point(bounds, index)
        return bounds.corner(index) if bounds.respond_to?(:corner)

        min = bounds.min
        max = bounds.max
        bits = index
        x = (bits & 1).zero? ? coord(min, 0) : coord(max, 0)
        y = (bits & 2).zero? ? coord(min, 1) : coord(max, 1)
        z = (bits & 4).zero? ? coord(min, 2) : coord(max, 2)
        point(x, y, z)
      end

      def coord(pt, axis)
        if pt.respond_to?(:x)
          return pt.x.to_f if axis == 0
          return pt.y.to_f if axis == 1

          return pt.z.to_f
        end
        pt[axis].to_f
      end

      def vector_xyz(vec)
        return nil if vec.nil?
        if vec.respond_to?(:x)
          return [vec.x.to_f, vec.y.to_f, vec.z.to_f]
        end
        return vec.map(&:to_f) if vec.is_a?(Array) && vec.size == 3

        nil
      end

      def first_vertex(face)
        if face.respond_to?(:vertices)
          verts = face.vertices
          v = verts.respond_to?(:[]) ? verts[0] : nil
          return v.position if v && v.respond_to?(:position)
          return v if v
        end
        nil
      end

      def each_vertex(face)
        return unless face.respond_to?(:vertices)

        face.vertices.each do |vert|
          yield vert.respond_to?(:position) ? vert.position : vert
        end
      end

      def subtract_points(a, b)
        [coord(a, 0) - coord(b, 0), coord(a, 1) - coord(b, 1), coord(a, 2) - coord(b, 2)]
      end

      def offset_point(origin, right, up, u, v)
        x = coord(origin, 0) + (right[0] * u) + (up[0] * v)
        y = coord(origin, 1) + (right[1] * u) + (up[1] * v)
        z = coord(origin, 2) + (right[2] * u) + (up[2] * v)
        point(x, y, z)
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

      def subtract3(a, b)
        [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
      end

      def scale3(a, s)
        [a[0] * s, a[1] * s, a[2] * s]
      end

      def length3(a)
        Math.sqrt((a[0] * a[0]) + (a[1] * a[1]) + (a[2] * a[2]))
      end

      def normalize3(a)
        len = length3(a)
        return nil if len < 1.0e-12

        [a[0] / len, a[1] / len, a[2] / len]
      end

      def model_path
        return nil unless @model.respond_to?(:path)

        path = @model.path.to_s
        path.empty? ? nil : path
      end

      def clamp_int(value, min, max, default)
        n = value.nil? ? default : value.to_i
        n = min if n < min
        n = max if n > max
        n
      end

      def round4(value)
        value.to_f.round(4)
      end

      # Обёртка, чтобы bounds модели пройти через bounds_m_of.
      class OpenStructBounds
        def initialize(bounds)
          @bounds = bounds
        end

        def bounds
          @bounds
        end
      end
    end
  end
end
