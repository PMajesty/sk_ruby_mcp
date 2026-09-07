# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Обход сцены и векторная арифметика для пакетов инструментов. Ожидает @model у включающего класса.
    # Всё через duck typing, чтобы тесты работали на заглушках без SketchUp.
    module SceneGeometry
      MathN = ArchitectMath

      private

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

      def point_xyz(pt)
        [coord(pt, 0), coord(pt, 1), coord(pt, 2)]
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

      def add3(a, b)
        [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
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

      def unique_material(base)
        name = base
        index = 2
        while @model.materials[name]
          name = "#{base} #{index}"
          index += 1
        end
        @model.materials.add(name)
      end

      # Материал с этим именем, при отсутствии создаётся с плоским цветом rgb.
      def material_for(name, rgb)
        existing = @model.materials[name]
        return existing if existing

        material = @model.materials.add(name)
        if defined?(Sketchup::Color)
          material.color = Sketchup::Color.new(rgb[0], rgb[1], rgb[2])
        else
          material.color = rgb
        end
        material
      end

      def hex_of(rgb)
        format('%02X%02X%02X', rgb[0], rgb[1], rgb[2])
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
    end
  end
end
