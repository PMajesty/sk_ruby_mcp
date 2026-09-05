# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Снимок сфокусированного документа. path пуст у несохранённого Untitled.
    ModelSnapshot = Struct.new(
      :path, :title, :modified, :faces, :bounds_m, :units, :root_entities,
      :objects, :objects_truncated, :tags, :materials, :selection, :edit_context,
      :identity,
      keyword_init: true
    ) do
      def untitled?
        path.nil? || path.empty?
      end
    end

    module ModelSnapshotFactory
      UNITS = {
        0 => 'in',
        1 => 'ft',
        2 => 'mm',
        3 => 'cm',
        4 => 'm',
        5 => 'yd'
      }.freeze
      OBJECT_CAP = 20
      READ_ERRORS = [NoMethodError, TypeError, ArgumentError].freeze

      module_function

      def from_model(model)
        return nil unless model && model.valid?

        path = model.respond_to?(:path) ? model.path.to_s : ''
        listed = objects(model)
        ModelSnapshot.new(
          path: path.empty? ? nil : path,
          title: model.respond_to?(:title) ? model.title.to_s : '',
          modified: model.respond_to?(:modified?) ? model.modified? : false,
          faces: faces(model),
          bounds_m: bounds_m(model),
          units: units(model),
          root_entities: root_entities(model),
          objects: listed[:items],
          objects_truncated: listed[:truncated],
          tags: tags(model),
          materials: materials(model),
          selection: selection_count(model),
          edit_context: edit_context(model),
          identity: model.respond_to?(:guid) ? model.guid.to_s : path
        )
      rescue *READ_ERRORS
        nil
      end

      def faces(model)
        return model.number_faces if model.respond_to?(:number_faces)

        model.entities.length
      rescue *READ_ERRORS
        nil
      end

      def bounds_m(model)
        bounds = model.bounds
        return nil if bounds.respond_to?(:empty?) && bounds.empty?

        min = point_m(bounds.min)
        max = point_m(bounds.max)
        return nil if min.nil? || max.nil?
        return nil unless ordered_finite_box?(min, max)

        { min: min, max: max }
      rescue *READ_ERRORS
        nil
      end

      def ordered_finite_box?(min, max)
        min.zip(max).all? do |low, high|
          low.finite? && high.finite? && low <= high && low.abs < 1.0e12 && high.abs < 1.0e12
        end
      end

      def point_m(point)
        %i[x y z].map { |axis| to_metres(point.send(axis)) }
      rescue *READ_ERRORS
        nil
      end

      def to_metres(value)
        return value.to_m.round(2) if value.respond_to?(:to_m)

        (value.to_f / 39.37007874015748).round(2)
      end

      def units(model)
        code = model.options['UnitsOptions']['LengthUnit']
        UNITS.fetch(code.to_i, 'in')
      rescue *READ_ERRORS
        nil
      end

      def root_entities(model)
        model.entities.length
      rescue *READ_ERRORS
        nil
      end

      def objects(model)
        items = []
        truncated = false
        model.entities.each do |entity|
          kind = entity_kind(entity)
          next unless kind
          if items.size >= OBJECT_CAP
            truncated = true
            break
          end
          items << object_row(entity, kind)
        end
        { items: items, truncated: truncated }
      rescue *READ_ERRORS
        { items: nil, truncated: nil }
      end

      def entity_kind(entity)
        name = entity.class.name.to_s
        return 'Group' if name.end_with?('Group') || entity.respond_to?(:entities) && !entity.respond_to?(:definition)
        return 'ComponentInstance' if name.end_with?('ComponentInstance') || entity.respond_to?(:definition)

        nil
      end

      def object_row(entity, kind)
        bounds = entity.respond_to?(:bounds) ? entity.bounds : nil
        row = {
          kind: kind,
          name: entity.respond_to?(:name) ? entity.name.to_s : '',
          bounds_m: size_m(bounds),
          at: origin_m(entity)
        }
        if kind == 'ComponentInstance' && entity.respond_to?(:definition)
          row[:definition] = entity.definition.respond_to?(:name) ? entity.definition.name.to_s : nil
        end
        row
      end

      def size_m(bounds)
        return [0.0, 0.0, 0.0] unless bounds

        width = to_metres(bounds.respond_to?(:width) ? bounds.width : delta(bounds, :x))
        height = to_metres(bounds.respond_to?(:height) ? bounds.height : delta(bounds, :y))
        depth = to_metres(bounds.respond_to?(:depth) ? bounds.depth : delta(bounds, :z))
        [width, height, depth]
      rescue *READ_ERRORS
        nil
      end

      def delta(bounds, axis)
        bounds.max.send(axis) - bounds.min.send(axis)
      end

      def origin_m(entity)
        bounds = entity.respond_to?(:bounds) ? entity.bounds : nil
        corner = bounds.respond_to?(:min) ? point_m(bounds.min) : nil
        return corner if corner

        transform = entity.respond_to?(:transformation) ? entity.transformation : nil
        origin = transform.respond_to?(:origin) ? transform.origin : nil
        return point_m(origin) if origin

        [0.0, 0.0, 0.0]
      rescue *READ_ERRORS
        nil
      end

      def tags(model)
        model.layers.length
      rescue *READ_ERRORS
        nil
      end

      def materials(model)
        model.materials.length
      rescue *READ_ERRORS
        nil
      end

      def selection_count(model)
        model.selection.length
      rescue *READ_ERRORS
        nil
      end

      def edit_context(model)
        return 'root' unless model.respond_to?(:active_path)

        path = model.active_path
        return 'root' if path.nil? || path.empty?

        last = path.last
        name = last.respond_to?(:name) ? last.name.to_s : last.class.name
        "inside #{name}"
      rescue *READ_ERRORS
        nil
      end
    end
  end
end
