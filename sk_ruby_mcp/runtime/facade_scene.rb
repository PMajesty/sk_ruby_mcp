# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Навигация по сцене для фасадного пакета: поиск объекта по имени, грани-хосты,
    # уже размещённые фасадные элементы, соседи объекта. Ничего не меняет.
    class FacadeScene
      include SceneGeometry

      DICT = 'SkRubyMcp.facade'
      ROLE_OPENING = 'opening'
      ROLE_BAND = 'band'
      ROLES = [ROLE_OPENING, ROLE_BAND].freeze
      SEARCH_DEPTH = 6
      HOST_DEPTH = 3
      LISTED_NAMES = 24

      def initialize(model)
        @model = model
      end

      # [entity, world transformation, path] или nil. Точное имя, затем путь, регистр, подстрока.
      def find_object(name)
        wanted = name.to_s
        return nil if wanted.empty?

        wanted_down = wanted.downcase
        exact = path_exact = ci_match = sub = nil
        each_container(@model.entities, identity_tr, '', 0) do |ent, world_tr, node_path|
          current = name_of(ent)
          exact ||= [ent, world_tr, node_path] if current == wanted
          path_down = node_path.downcase
          path_exact ||= [ent, world_tr, node_path] if path_down == wanted_down || path_down.end_with?("/#{wanted_down}")
          ci_match ||= [ent, world_tr, node_path] if current.downcase == wanted_down
          sub ||= [ent, world_tr, node_path] if !current.empty? && current.downcase.include?(wanted_down)
        end
        exact || path_exact || ci_match || sub
      end

      def not_found(name)
        names = []
        each_container(@model.entities, identity_tr, '', 0) do |_ent, _tr, node_path|
          names << node_path if names.length < LISTED_NAMES
        end
        {
          'ok' => false,
          'error' => 'object_not_found',
          'message' => "No group or component named #{name.to_s.inspect}. Available: #{names.join(', ')}",
          'retry' => true
        }
      end

      # Все группы и компоненты с их мировой трансформацией и путём, кроме фасадных элементов.
      def each_container(entities, tr, path, depth, &block)
        return if depth > SEARCH_DEPTH

        each_entity(entities) do |ent|
          kind = classify(ent)
          next if kind.nil? || facade_element?(ent)

          child_tr = multiply_tr(tr, read_transformation(ent))
          name = name_of(ent)
          label = name.empty? ? '(unnamed)' : name
          node_path = path.empty? ? label : "#{path}/#{label}"
          block.call(ent, child_tr, node_path)
          each_container(child_entities(ent, kind), child_tr, node_path, depth + 1, &block)
        end
      end

      # Грани самой массы: прямые грани объекта и грани вложенных контейнеров, не являющихся фасадными элементами.
      def each_host_face(ent, world_tr, depth = 0, &block)
        kind = classify(ent)
        ents = kind ? child_entities(ent, kind) : nil
        return if ents.nil?

        each_entity(ents) do |child|
          if face?(child)
            block.call(child, world_tr)
            next
          end
          next if depth >= HOST_DEPTH || facade_element?(child)

          child_kind = classify(child)
          next if child_kind.nil?

          each_host_face(child, multiply_tr(world_tr, read_transformation(child)), depth + 1, &block)
        end
      end

      def each_facade_element(ent, depth = 0, &block)
        kind = classify(ent)
        ents = kind ? child_entities(ent, kind) : nil
        return if ents.nil?

        each_entity(ents) do |child|
          child_kind = classify(child)
          next if child_kind.nil?

          if facade_element?(child)
            block.call(child)
            next
          end
          each_facade_element(child, depth + 1, &block) if depth < HOST_DEPTH
        end
      end

      # Соседи объекта: контейнеры в той же коллекции, что и он сам (без него).
      def siblings_of(ent)
        parent_entities = parent_entities_of(ent)
        return [] if parent_entities.nil?

        list = []
        each_entity(parent_entities) do |child|
          next if child.equal?(ent) || classify(child).nil? || facade_element?(child)

          list << child
        end
        list
      end

      def facade_element?(ent)
        return false unless ent.respond_to?(:get_attribute)

        ROLES.include?(ent.get_attribute(DICT, 'role').to_s)
      rescue StandardError, ScriptError
        false
      end

      def name_of(ent)
        ent.respond_to?(:name) ? ent.name.to_s : ''
      end

      def entity_id(ent)
        return ent.persistent_id if ent.respond_to?(:persistent_id)
        return ent.entityID if ent.respond_to?(:entityID)

        ent.object_id
      end

      private

      def parent_entities_of(ent)
        parent = ent.respond_to?(:parent) ? ent.parent : nil
        return nil if parent.nil?
        return parent.entities if parent.respond_to?(:entities)
        return parent if parent.respond_to?(:to_a)

        nil
      end
    end
  end
end
