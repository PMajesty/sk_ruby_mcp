# frozen_string_literal: true

require 'fileutils'

module SkRubyMcp
  module Runtime
    # Снимок вьюпорта для фасадной работы: заданная камера, чистые опции отрисовки, изоляция объекта,
    # ID-проход плоскими цветами. Все правки модели идут внутри операции, которая откатывается.
    class FacadeCapture
      include SceneGeometry

      RENDER_KEYS = %w[
        RenderMode EdgeDisplayMode DrawSilhouettes DrawLineEnds DrawDepthQue DrawProfilesOnly
        DisplayFog DrawGround DrawHorizon DisplayWatermarks DisplayDims DisplayText
        DisplaySketchAxes DisplayInstanceAxes DisplayColorByLayer BackgroundColor
        HorizonSkyColor HorizonGroundColor SkyColor
      ].freeze
      SHADOW_KEYS = %w[DisplayShadows UseSunForAllShading Light Dark].freeze
      ID_MODES = %w[objects faces].freeze
      ID_OTHER_RGB = [40, 40, 40].freeze
      DEFAULT_BACKGROUND = [204, 204, 201].freeze
      MAX_SIDE = 8192
      MIN_SIDE = 64

      def initialize(model, scene: nil)
        @model = model
        @scene = scene || FacadeScene.new(model)
      end

      def capture(path:, width: nil, height: nil, camera: nil, isolate: nil, id_pass: nil, edges: false,
                  background: nil, hide_facade: false, keep_camera: false, antialias: nil, transparent: false)
        view = @model.respond_to?(:active_view) ? @model.active_view : nil
        unless view && view.respond_to?(:write_image)
          return { 'ok' => false, 'error' => 'capture_failed', 'message' => 'The focused document has no viewport to photograph.', 'retry' => false }
        end
        if view.respond_to?(:vpwidth) && view.vpwidth.to_i < 1
          return { 'ok' => false, 'error' => 'view_not_ready', 'message' => 'The SketchUp viewport is not ready (minimized or not yet painted).', 'retry' => true }
        end

        target = nil
        if isolate || id_pass
          found = @scene.find_object(isolate || id_pass['object'])
          return @scene.not_found(isolate || id_pass['object']) if found.nil?

          target = found[0]
        end
        size = frame_size(view, width, height)
        return size if size.is_a?(Hash) && size['ok'] == false

        restore = []
        colors = nil
        opened = start_scratch_operation
        begin
          apply_camera(view, camera, restore, keep_camera) if camera
          apply_render_options(restore, edges: edges == true, background: background, id_pass: !id_pass.nil?)
          hide_siblings(target, restore) if isolate
          hide_facade_elements([target], restore) if target && hide_facade && !id_pass
          hide_facade_elements([target] + @scene.siblings_of(target), restore) if id_pass
          colors = paint_ids(target, id_pass, restore) if id_pass
          @model.selection.clear if @model.respond_to?(:selection) && @model.selection.respond_to?(:clear)
          written = write(view, path, size[0], size[1], id_pass ? false : antialias != false, transparent == true)
        ensure
          restore.reverse_each { |step| safely(&step) }
          abort_scratch_operation if opened
        end
        unless written
          return { 'ok' => false, 'error' => 'capture_failed', 'message' => 'SketchUp could not write the image.', 'retry' => true }
        end

        reply = {
          'ok' => true,
          'image_path' => path,
          'width' => size[0],
          'height' => size[1],
          'viewport' => viewport_size(view),
          'isolated' => target && @scene.name_of(target),
          'id_pass' => id_pass && id_pass['mode'],
          'colors' => colors,
          'path' => model_path
        }
        colors ? reply.merge(write_color_table(path, colors, size, target)) : reply
      end

      # Таблица цветов ID-прохода ложится рядом со снимком: <image>.colors.json, чтобы скрипты нашли её сами.
      def self.color_table_path(image_path)
        base = image_path.to_s.sub(/\.[A-Za-z0-9]+\z/, '')
        "#{base}.colors.json"
      end

      private

      def write_color_table(image_path, colors, size, target)
        sidecar = self.class.color_table_path(image_path)
        table = colors.merge('object' => @scene.name_of(target), 'image_path' => image_path, 'width' => size[0], 'height' => size[1])
        File.write(sidecar, JSON.pretty_generate(table))
        { 'colors_path' => sidecar }
      rescue SystemCallError, IOError => error
        { 'colors_path' => nil, 'write_error' => "#{error.class}: #{error.message}" }
      end

      def frame_size(view, width, height)
        w = width.to_i
        h = height.to_i
        if w <= 0 || h <= 0
          vp = viewport_size(view)
          return { 'ok' => false, 'error' => 'unknown_arguments', 'message' => 'width and height are required when the viewport size is unknown', 'retry' => false } if vp.nil?

          w = vp[0] if w <= 0
          h = vp[1] if h <= 0
        end
        if w < MIN_SIDE || h < MIN_SIDE || w > MAX_SIDE || h > MAX_SIDE
          return { 'ok' => false, 'error' => 'unknown_arguments', 'message' => "width and height must be #{MIN_SIDE}..#{MAX_SIDE} px", 'retry' => false }
        end

        [w, h]
      end

      def viewport_size(view)
        return nil unless view.respond_to?(:vpwidth) && view.respond_to?(:vpheight)

        [view.vpwidth.to_i, view.vpheight.to_i]
      end

      def start_scratch_operation
        return false unless @model.respond_to?(:start_operation)

        @model.start_operation('MCP facade_capture', true)
        true
      rescue StandardError, ScriptError
        false
      end

      def abort_scratch_operation
        @model.abort_operation if @model.respond_to?(:abort_operation)
      rescue StandardError, ScriptError
        nil
      end

      def safely
        yield
      rescue StandardError, ScriptError => error
        Log.warn("facade_capture restore step failed: #{error.class}: #{error.message}") if defined?(Log)
      end

      def apply_camera(view, camera, restore, keep_camera)
        cam = view.camera
        return unless cam

        saved = {
          eye: cam.eye, target: cam.target, up: cam.up,
          perspective: cam.respond_to?(:perspective?) ? cam.perspective? : true,
          fov: cam.respond_to?(:fov) ? cam.fov : nil
        }
        cam.set(point(*camera[:eye]), point(*camera[:target]), vector(camera[:up]))
        cam.perspective = true if cam.respond_to?(:perspective=)
        cam.fov = camera[:fov].to_f if cam.respond_to?(:fov=) && camera[:fov].to_f.positive?
        return if keep_camera

        restore << lambda do
          cam.set(saved[:eye], saved[:target], saved[:up])
          cam.perspective = saved[:perspective] if cam.respond_to?(:perspective=)
          cam.fov = saved[:fov] if saved[:fov] && saved[:perspective] && cam.respond_to?(:fov=)
        end
      end

      def apply_render_options(restore, edges:, background:, id_pass:)
        options = @model.respond_to?(:rendering_options) ? @model.rendering_options : nil
        shadows = @model.respond_to?(:shadow_info) ? @model.shadow_info : nil
        saved_options = snapshot(options, RENDER_KEYS)
        saved_shadows = snapshot(shadows, SHADOW_KEYS)
        restore << -> { write_back(options, saved_options) }
        restore << -> { write_back(shadows, saved_shadows) }
        return if options.nil?

        set_option(options, 'EdgeDisplayMode', edges ? 1 : 0)
        %w[DrawSilhouettes DrawLineEnds DrawDepthQue DrawProfilesOnly DisplayFog DrawGround DisplayWatermarks
           DisplayDims DisplayText DisplaySketchAxes DisplayInstanceAxes DisplayColorByLayer].each do |key|
          set_option(options, key, false)
        end
        set_option(options, 'DrawHorizon', !id_pass)
        rgb = if id_pass
                [0, 0, 0]
              elsif background.to_s == 'default'
                DEFAULT_BACKGROUND
              else
                parse_color(background)
              end
        if rgb
          %w[BackgroundColor HorizonSkyColor HorizonGroundColor SkyColor].each { |key| set_option(options, key, color(rgb)) }
        end
        if id_pass
          set_option(options, 'RenderMode', 2)
          set_option(shadows, 'DisplayShadows', false)
          set_option(shadows, 'UseSunForAllShading', true)
          set_option(shadows, 'Light', 0)
          set_option(shadows, 'Dark', 80)
        else
          set_option(shadows, 'DisplayShadows', false)
        end
      end

      def snapshot(options, keys)
        return {} if options.nil?

        keys.each_with_object({}) do |key, acc|
          value = read_option(options, key)
          acc[key] = value unless value.nil?
        end
      end

      def write_back(options, saved)
        return if options.nil?

        saved.each { |key, value| set_option(options, key, value) }
      end

      def read_option(options, key)
        options[key]
      rescue StandardError, ScriptError
        nil
      end

      def set_option(options, key, value)
        return if options.nil?

        options[key] = value
      rescue StandardError, ScriptError
        nil
      end

      def hide_siblings(target, restore)
        @scene.siblings_of(target).each { |sibling| hide(sibling, restore) }
        show(target, restore)
      end

      def hide_facade_elements(containers, restore)
        containers.each do |container|
          @scene.each_facade_element(container) { |element| hide(element, restore) }
        end
      end

      def hide(ent, restore)
        return unless ent.respond_to?(:hidden=) && ent.respond_to?(:hidden?)

        was = ent.hidden?
        return if was

        ent.hidden = true
        restore << -> { ent.hidden = was if alive?(ent) }
      end

      def show(ent, restore)
        return unless ent.respond_to?(:hidden=) && ent.respond_to?(:hidden?)

        was = ent.hidden?
        return unless was

        ent.hidden = false
        restore << -> { ent.hidden = was if alive?(ent) }
      end

      # ID-проход: objects — объект и соседи разными цветами; faces — грани объекта разными, соседи серым.
      def paint_ids(target, id_pass, restore)
        mode = ID_MODES.include?(id_pass['mode'].to_s) ? id_pass['mode'].to_s : 'objects'
        table = []
        created = []
        other = id_material(ID_OTHER_RGB, created)
        if mode == 'faces'
          index = 0
          @scene.each_host_face(target, identity_tr) do |face, _tr|
            rgb = FacadeMath.id_color(index)
            paint_face(face, id_material(rgb, created), restore)
            table << { 'index' => index, 'id' => @scene.entity_id(face), 'rgb' => rgb, 'hex' => hex_of(rgb) }
            index += 1
          end
          @scene.siblings_of(target).each { |sibling| paint_container(sibling, other, restore) }
        else
          ([target] + @scene.siblings_of(target)).each_with_index do |container, index|
            rgb = FacadeMath.id_color(index)
            paint_container(container, id_material(rgb, created), restore)
            table << { 'index' => index, 'name' => @scene.name_of(container), 'id' => @scene.entity_id(container), 'rgb' => rgb, 'hex' => hex_of(rgb) }
          end
        end
        restore << -> { created.each { |material| remove_material(material) } }
        { 'mode' => mode, 'other_rgb' => ID_OTHER_RGB, 'background_rgb' => [0, 0, 0], 'items' => table }
      end

      def id_material(rgb, created)
        name = "MCP id #{hex_of(rgb)}"
        existed = @model.materials[name]
        material = material_for(name, rgb)
        created << material unless existed
        material
      end

      def remove_material(material)
        @model.materials.remove(material) if @model.materials.respond_to?(:remove)
      rescue StandardError, ScriptError
        nil
      end

      def paint_container(container, material, restore)
        if container.respond_to?(:material=)
          was = container.material
          container.material = material
          restore << -> { container.material = was if alive?(container) }
        end
        @scene.each_host_face(container, identity_tr) { |face, _tr| paint_face(face, material, restore) }
      end

      def paint_face(face, material, restore)
        front = face.material
        back = face.respond_to?(:back_material) ? face.back_material : nil
        face.material = material
        face.back_material = material if face.respond_to?(:back_material=)
        restore << lambda do
          next unless alive?(face)

          face.material = front
          face.back_material = back if face.respond_to?(:back_material=)
        end
      end

      def write(view, path, width, height, antialias, transparent)
        FileUtils.mkdir_p(File.dirname(path))
        view.refresh if view.respond_to?(:refresh)
        ok = view.write_image(
          filename: path,
          width: width,
          height: height,
          antialias: antialias,
          compression: 1.0,
          transparent: transparent
        )
        ok && File.file?(path) && File.size(path).positive?
      rescue ArgumentError, TypeError
        ok = view.write_image(path, width, height, antialias, 1.0)
        ok && File.file?(path) && File.size(path).positive?
      end

      def color(rgb)
        defined?(Sketchup::Color) ? Sketchup::Color.new(rgb[0], rgb[1], rgb[2]) : rgb
      end

      def vector(xyz)
        defined?(Geom::Vector3d) ? Geom::Vector3d.new(*xyz) : xyz
      end
    end
  end
end
