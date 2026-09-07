# frozen_string_literal: true

require 'json'

module SkRubyMcp
  module Tools
    # Фасадный пакет: грани объекта в кадре камеры, проёмы как приклеенные режущие компоненты,
    # пояса, покраска, ведомость и снимки. По умолчанию включён; выключается настройкой facade_pack.
    module FacadePack
      SETTING_KEY = 'facade_pack'

      class << self
        def instances(session:, attach:)
          [
            Faces.new(session: session, attach: attach),
            PlaceOpenings.new(session: session, attach: attach),
            PlaceBands.new(session: session, attach: attach),
            Paint.new(session: session, attach: attach),
            List.new(session: session, attach: attach),
            Remove.new(session: session, attach: attach),
            Verify.new(session: session, attach: attach),
            Capture.new(session: session, attach: attach)
          ]
        end
      end

      FACADE_OUTPUT_SCHEMA = {
        type: 'object',
        properties: {
          ok: { type: 'boolean' },
          error: { type: 'string' },
          message: { type: 'string' },
          retry: { type: 'boolean' },
          instead: { type: 'string' },
          next: { type: 'string' },
          path: { type: %w[string null] },
          object: { type: 'string' },
          object_path: { type: 'string' },
          shared_definition: { type: 'integer' },
          bounds_m: { type: 'object' },
          storeys_m: { type: 'array' },
          storey_cells: { type: 'array' },
          faces: { type: 'array' },
          count: { type: 'integer' },
          image: { type: 'object' },
          camera: { type: 'object' },
          requested: { type: 'integer' },
          placed: { type: 'integer' },
          failed: { type: 'integer' },
          skipped: { type: 'integer' },
          removed: { type: 'integer' },
          painted: { type: 'integer' },
          material: { type: 'string' },
          missing_faces: { type: 'array' },
          items: { type: 'array' },
          openings: { type: 'integer' },
          bands: { type: 'integer' },
          matched: { type: 'integer' },
          mismatched: { type: 'array' },
          missing: { type: 'array' },
          extra: { type: 'array' },
          tolerance_m: { type: 'number' },
          expected: { type: 'integer' },
          live: { type: 'integer' },
          schedule_errors: { type: 'array' },
          image_path: { type: 'string' },
          written: { type: %w[string null] },
          write_error: { type: 'string' },
          width: { type: 'integer' },
          height: { type: 'integer' },
          viewport: { type: 'array' },
          isolated: { type: 'string' },
          id_pass: { type: 'string' },
          colors: { type: 'object' },
          colors_path: { type: %w[string null] }
        },
        required: ['ok']
      }.freeze

      CAMERA_SCHEMA = {
        type: 'object',
        description: 'Camera in metres: eye_m [x,y,z], target_m [x,y,z], up [x,y,z], fov_deg, fov_is_height (default true). Omit to use the live viewport camera.',
        properties: {
          eye_m: { type: 'array', items: { type: 'number' }, minItems: 3, maxItems: 3 },
          target_m: { type: 'array', items: { type: 'number' }, minItems: 3, maxItems: 3 },
          up: { type: 'array', items: { type: 'number' }, minItems: 3, maxItems: 3 },
          fov_deg: { type: 'number' },
          fov_is_height: { type: 'boolean' }
        },
        required: %w[eye_m target_m],
        additionalProperties: false
      }.freeze

      ITEM_SCHEMA = {
        type: 'object',
        description: 'One opening rule. face (id from facade_faces). kind small_window|large_window|glass_door|storefront|custom. Horizontal: x0 and x1 as fractions 0..1 of the face width from its left edge as the camera sees it, or u0_m + width_m, or x_center + width_m. Vertical: storey (index from storey_cells), storeys (list or "all"), or z0_m + z1_m world metres; y0/y1 fractions of the storey cell or sill_m/head_m override the kind defaults. count repeats the opening count times inside x0..x1 (each w fraction or width_m). frame_edges subset of left,right,top,bottom; frame_w_m (default 0.3), frame_out_m (default 0.15, keep 0.1 or more so the frame does not z-fight the wall from far cameras), recess_m (default 0.25), frame_color, glass_color, mullions, transom, label.',
        additionalProperties: true
      }.freeze

      # Разбор камеры из аргументов: объект в метрах или JSON-файл со снимком состояния в дюймах.
      module CameraArgument
        module_function

        def resolve(camera, camera_file, probe: nil)
          return from_file(camera_file, probe) if camera_file
          return nil if camera.nil?
          raise ArgumentError, 'camera must be an object' unless camera.is_a?(Hash)

          eye = triple(camera['eye_m'], 'camera.eye_m')
          target = triple(camera['target_m'], 'camera.target_m')
          up = triple(camera['up'], 'camera.up') || [0.0, 0.0, 1.0]
          {
            eye: eye.map { |n| Runtime::ArchitectMath.m_to_in(n) },
            target: target.map { |n| Runtime::ArchitectMath.m_to_in(n) },
            up: up,
            fov: camera['fov_deg'].nil? ? 35.0 : camera['fov_deg'].to_f,
            fov_is_height: camera['fov_is_height'] != false
          }
        end

        def from_file(path, probe)
          cleaned = Runtime::LocalPath.existing_file(path, probe: probe)
          data = JSON.parse(File.read(cleaned))
          block = data.is_a?(Hash) && data['camera'].is_a?(Hash) ? data['camera'] : data
          raise ArgumentError, 'camera_file needs eye, target and up in inches' unless block.is_a?(Hash) && block['eye'] && block['target']

          {
            eye: triple(block['eye'], 'camera.eye'),
            target: triple(block['target'], 'camera.target'),
            up: triple(block['up'], 'camera.up') || [0.0, 0.0, 1.0],
            fov: block['fov'].nil? ? 35.0 : block['fov'].to_f,
            fov_is_height: block['fov_is_height'] != false
          }
        end

        def triple(value, name)
          return nil if value.nil?
          unless value.is_a?(Array) && value.size == 3 && value.all? { |n| n.is_a?(Numeric) }
            raise ArgumentError, "#{name} must be [x, y, z] numbers"
          end

          value.map(&:to_f)
        end
      end

      class FacadeTool < ModelTool
        def output_schema
          FACADE_OUTPUT_SCHEMA
        end

        private

        def id_list(value, name)
          return nil if value.nil?
          raise ArgumentError, "#{name} must be an array of ids" unless value.is_a?(Array)

          value.map(&:to_s)
        end

        def object_hash(value, name)
          return {} if value.nil?
          raise ArgumentError, "#{name} must be an object" unless value.is_a?(Hash)

          value
        end

        def item_list(value, name)
          raise ArgumentError, "#{name} must be a non-empty array of objects" unless value.is_a?(Array) && !value.empty?
          raise ArgumentError, "#{name} entries must be objects" unless value.all? { |item| item.is_a?(Hash) }

          value
        end

        def required_text(arguments, key)
          value = text(arguments[key])
          raise ArgumentError, "#{key} is required" if value.to_s.strip.empty?

          value
        end

        def optional_local_file(value)
          raw = text(value)
          return nil if raw.to_s.strip.empty?

          Runtime::LocalPath.existing_file(raw, probe: @session.path_probe)
        end

        def optional_output_file(value)
          raw = text(value)
          return nil if raw.to_s.strip.empty?

          Runtime::LocalPath.writable_file(raw, probe: @session.path_probe)
        end

        def required_output_file(arguments, key)
          Runtime::LocalPath.writable_file(required_text(arguments, key), probe: @session.path_probe)
        end

        def camera_from(arguments)
          CameraArgument.resolve(
            arguments['camera'],
            arguments['camera_file'],
            probe: @session.path_probe
          )
        end

        def ops(model)
          Runtime::FacadeOps.new(model)
        end
      end

      class Faces < FacadeTool
        NAME = 'facade_faces'
        TITLE = 'Façade faces of an object'
        DESCRIPTION = <<~TEXT.strip
          List the vertical faces of a named group or component that face the camera, with sizes in metres, world corners, the pixel quad of each face in an image of image_width×image_height taken with that camera, storey levels found from thin floor plates, and storey cells (index, z0_m, z1_m). Faces are ordered left to right as the camera sees them; x0/x1 fractions in facade_place_openings count from the same left edge. Use this first: its face ids feed every other facade tool, and its pixel quads let a script rectify each face out of a photo or a capture. Camera: camera (metres) or camera_file (a JSON snapshot with eye/target/up/fov in inches); omit both for the live viewport camera. make_unique true makes a shared component unique so face ids stay valid; otherwise nothing changes.
          Arguments: object (required name or nested path). camera, camera_file (optional). image_width, image_height (optional, default the viewport size). min_area_m2 (default 1.0). min_dot (default 0.12; smaller keeps more grazing faces). make_unique (default false). write_to (optional file path; the same reply is also written there as JSON for scripts such as facade_rectify.py).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            object: { type: 'string', description: 'Group or component name, or nested path (Building/Form 3).' },
            camera: CAMERA_SCHEMA,
            camera_file: { type: 'string', description: 'JSON file with a camera block: eye, target, up in inches, fov in degrees.' },
            image_width: { type: 'integer', minimum: 64, maximum: 8192 },
            image_height: { type: 'integer', minimum: 64, maximum: 8192 },
            min_area_m2: { type: 'number', description: 'Skip faces smaller than this (default 1.0).' },
            min_dot: { type: 'number', description: 'Skip faces whose normal is more oblique to the camera than this (default 0.12).' },
            make_unique: { type: 'boolean', description: 'Make a shared component unique first (default false).' },
            write_to: { type: 'string', description: 'Also write the reply as JSON to this file.' }
          },
          required: ['object'],
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = { title: TITLE, readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }.freeze

        def parse_arguments(arguments)
          {
            object: required_text(arguments, 'object'),
            camera: camera_from(arguments),
            image_w: integer(arguments['image_width'], 'image_width'),
            image_h: integer(arguments['image_height'], 'image_height'),
            min_area_m2: number(arguments['min_area_m2'], 'min_area_m2'),
            min_dot: number(arguments['min_dot'], 'min_dot'),
            make_unique: boolean(arguments['make_unique'], 'make_unique') == true,
            write_to: optional_output_file(arguments['write_to'])
          }
        end

        def run_on_model(model, parsed)
          write_to = parsed.delete(:write_to)
          result = if parsed[:make_unique]
                     with_operation(model, 'MCP facade_faces make_unique') { ops(model).faces(**parsed) }
                   else
                     ops(model).faces(**parsed)
                   end
          write_reply(result, write_to)
        end

        private

        def write_reply(result, write_to)
          return result if write_to.to_s.strip.empty? || result['ok'] != true

          File.write(write_to, JSON.pretty_generate(result))
          result.merge('written' => write_to)
        rescue SystemCallError, IOError => error
          result.merge('written' => nil, 'write_error' => "#{error.class}: #{error.message}")
        end
      end

      class PlaceOpenings < FacadeTool
        NAME = 'facade_place_openings'
        TITLE = 'Place windows and doors from a schedule'
        DESCRIPTION = <<~TEXT.strip
          Place windows and doors on the faces of a named object from a schedule. Each opening is a glued cutting component with a recessed glass pane, reveals and a proud frame on the chosen edges, so the wall is never cut: facade_remove restores the plain mass. Positions are relative to the face: x0/x1 fractions of the face width from its camera-left edge (or u0_m + width_m), storey index from facade_faces storey_cells (or z0_m/z1_m world metres). Kind defaults: small_window sits from 25% of the storey up to the storey line with frame left, right and bottom; large_window fills the storey with frame left and right; glass_door from the floor to 66% with frame left, right and top; storefront to 80%; custom needs y0/y1 or sill_m/head_m. count with x0..x1 spreads count identical openings evenly; storeys "all" repeats on every storey. defaults apply to every item; item keys win. replace true first removes existing openings on the faces the schedule touches. The reply lists each placed opening with its id, or why it failed; the whole call is one undo step.
          Arguments: object (required). items (required array of opening rules). defaults (optional object with the same keys, plus storeys_m to override the storey levels). replace (optional boolean, default false).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            object: { type: 'string', description: 'Group or component name, or nested path.' },
            items: { type: 'array', items: ITEM_SCHEMA, minItems: 1, description: 'Opening rules.' },
            defaults: { type: 'object', description: 'Defaults merged under every item (kind, frame_*, recess_m, glass_color, storeys_m, ...).', additionalProperties: true },
            replace: { type: 'boolean', description: 'Remove existing openings on the touched faces first (default false).' }
          },
          required: %w[object items],
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = { title: TITLE, readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false }.freeze

        def parse_arguments(arguments)
          {
            object: required_text(arguments, 'object'),
            items: item_list(arguments['items'], 'items'),
            defaults: object_hash(arguments['defaults'], 'defaults'),
            replace: boolean(arguments['replace'], 'replace') == true
          }
        end

        def run_on_model(model, parsed)
          with_operation(model, 'MCP facade_place_openings') { ops(model).place_openings(**parsed) }
        end
      end

      class PlaceBands < FacadeTool
        NAME = 'facade_place_bands'
        TITLE = 'Place belts, cornices and plinths'
        DESCRIPTION = <<~TEXT.strip
          Add horizontal bands (belt courses, cornices, plinths) to the faces of a named object as thin proud groups, one per face per level, without touching the wall. z_m lists world heights in metres; align says whether each z is the bottom (default), center or top of the band. Omit faces to band every vertical face of the object, or pass face ids from facade_faces. Use storeys_m from facade_faces for belts on every storey line. Bands are listed by facade_list and removed by facade_remove role band.
          Arguments: object (required). z_m (required array of metres). faces (optional array of face ids). thickness_m (default 0.4). depth_m (default 0.2, how far the band stands proud; keep it 0.15 m or more, thinner relief z-fights at city-scale camera distances). color (default #F2EFE9). inset_m (default 0). align bottom|center|top (default bottom). label (optional).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            object: { type: 'string' },
            z_m: { type: 'array', items: { type: 'number' }, minItems: 1, description: 'World heights of the bands in metres.' },
            faces: { type: 'array', items: { type: %w[string integer] }, description: 'Face ids from facade_faces; default all vertical faces.' },
            thickness_m: { type: 'number' },
            depth_m: { type: 'number' },
            color: { type: 'string', description: 'Hex #RRGGBB or r,g,b.' },
            inset_m: { type: 'number', description: 'Keep-out from the face ends.' },
            align: { type: 'string', enum: %w[bottom center top] },
            label: { type: 'string' }
          },
          required: %w[object z_m],
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = { title: TITLE, readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false }.freeze

        def parse_arguments(arguments)
          levels = arguments['z_m']
          raise ArgumentError, 'z_m must be a non-empty array of metres' unless levels.is_a?(Array) && !levels.empty? && levels.all? { |n| n.is_a?(Numeric) }

          {
            object: required_text(arguments, 'object'),
            z_m: levels.map(&:to_f),
            faces: id_list(arguments['faces'], 'faces'),
            thickness_m: number(arguments['thickness_m'], 'thickness_m'),
            depth_m: number(arguments['depth_m'], 'depth_m'),
            color: text(arguments['color']),
            inset_m: number(arguments['inset_m'], 'inset_m'),
            align: text(arguments['align']),
            label: text(arguments['label'])
          }
        end

        def run_on_model(model, parsed)
          with_operation(model, 'MCP facade_place_bands') { ops(model).place_bands(**parsed) }
        end
      end

      class Paint < FacadeTool
        NAME = 'facade_paint'
        TITLE = 'Paint an object or its faces'
        DESCRIPTION = <<~TEXT.strip
          Paint the whole object (omit faces) or specific faces (ids from facade_faces) with a flat color, an existing material name, or an image texture with a real-world tile size. clear true removes the material instead. Painting is reversible and never changes geometry; openings and bands keep their own colors.
          Arguments: object (required). faces (optional array of face ids). color (hex or r,g,b). material (existing material name). texture (image path) with texture_size_m (tile width in metres). clear (boolean).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            object: { type: 'string' },
            faces: { type: 'array', items: { type: %w[string integer] } },
            color: { type: 'string' },
            material: { type: 'string' },
            texture: { type: 'string', description: 'Path to a PNG or JPG used as a tiling texture.' },
            texture_size_m: { type: 'number', description: 'Real-world width of one texture tile in metres.' },
            clear: { type: 'boolean' }
          },
          required: ['object'],
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = { title: TITLE, readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false }.freeze

        def parse_arguments(arguments)
          {
            object: required_text(arguments, 'object'),
            faces: id_list(arguments['faces'], 'faces'),
            color: text(arguments['color']),
            material: text(arguments['material']),
            texture: optional_local_file(arguments['texture']),
            texture_size_m: number(arguments['texture_size_m'], 'texture_size_m'),
            clear: boolean(arguments['clear'], 'clear') == true
          }
        end

        def run_on_model(model, parsed)
          with_operation(model, 'MCP facade_paint') { ops(model).paint(**parsed) }
        end
      end

      class List < FacadeTool
        NAME = 'facade_list'
        TITLE = 'List placed façade elements'
        DESCRIPTION = <<~TEXT.strip
          List the openings and bands placed on a named object with the values they were placed with: face id, kind, u0_m from the face's left edge, width_m, z0_m, z1_m, storey, frame_edges, label, plus whether each opening is still glued to its face. This is the model side of the schedule; compare it with your schedule or call facade_verify to get the diff. Does not change the model.
          Arguments: object (required). role opening|band|all (default all).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            object: { type: 'string' },
            role: { type: 'string', enum: %w[opening band all] }
          },
          required: ['object'],
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = { title: TITLE, readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }.freeze

        def parse_arguments(arguments)
          { object: required_text(arguments, 'object'), role: text(arguments['role']) }
        end

        def run_on_model(model, parsed)
          ops(model).list(**parsed)
        end
      end

      class Remove < FacadeTool
        NAME = 'facade_remove'
        TITLE = 'Remove façade elements'
        DESCRIPTION = <<~TEXT.strip
          Remove openings and bands from a named object, restoring the plain mass under them. Filter by role, by face ids, or by element ids from facade_list or facade_place_openings; with no filter everything the facade tools placed on the object goes. Materials painted with facade_paint stay (use facade_paint clear). One undo step.
          Arguments: object (required). role opening|band|all (default all). faces (optional face ids). ids (optional element ids).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            object: { type: 'string' },
            role: { type: 'string', enum: %w[opening band all] },
            faces: { type: 'array', items: { type: %w[string integer] } },
            ids: { type: 'array', items: { type: %w[string integer] } }
          },
          required: ['object'],
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = { title: TITLE, readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false }.freeze

        def parse_arguments(arguments)
          {
            object: required_text(arguments, 'object'),
            role: text(arguments['role']),
            faces: id_list(arguments['faces'], 'faces'),
            ids: id_list(arguments['ids'], 'ids')
          }
        end

        def run_on_model(model, parsed)
          with_operation(model, 'MCP facade_remove') { ops(model).remove(**parsed) }
        end
      end

      class Verify < FacadeTool
        NAME = 'facade_verify'
        TITLE = 'Diff a schedule against the model'
        DESCRIPTION = <<~TEXT.strip
          Resolve a schedule exactly as facade_place_openings would and compare it with the openings actually on the object. Returns matched count, mismatched (same face and overlap but moved or resized, with deltas in metres), missing (in the schedule, not in the model), extra (in the model, not in the schedule) and schedule_errors (rules that cannot be resolved). ok is true only when all four are empty. Use it after placing and before any visual check. Does not change the model.
          Arguments: object (required). items (required, the same schedule). defaults (optional). tol_m (default 0.15).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            object: { type: 'string' },
            items: { type: 'array', items: ITEM_SCHEMA, minItems: 1 },
            defaults: { type: 'object', additionalProperties: true },
            tol_m: { type: 'number' }
          },
          required: %w[object items],
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = { title: TITLE, readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }.freeze

        def parse_arguments(arguments)
          {
            object: required_text(arguments, 'object'),
            items: item_list(arguments['items'], 'items'),
            defaults: object_hash(arguments['defaults'], 'defaults'),
            tol_m: number(arguments['tol_m'], 'tol_m')
          }
        end

        def run_on_model(model, parsed)
          ops(model).verify(**parsed)
        end
      end

      class Capture < FacadeTool
        NAME = 'facade_capture'
        TITLE = 'Write a clean capture or an ID pass'
        DESCRIPTION = <<~TEXT.strip
          Write a PNG of the model to image_path with the given camera and clean render settings (no edges unless edges true, no shadows, no axes or text). isolate true hides every sibling of object so only that object is visible. id_pass objects paints the object and its siblings in flat distinct colors on black; id_pass faces paints each face of object in its own color and the siblings dark grey; the reply carries the color table and the same table is written next to the image as <image>.colors.json so a script can mask each object or face in the image and detect occlusion. hide_facade true hides placed openings and bands. Everything is restored afterwards, including the camera unless keep_camera is true; the model is left unchanged. Use the same camera and image size as facade_faces so pixel quads line up. The image is written to disk and not returned inline.
          Arguments: image_path (required). width, height (default the viewport size). camera or camera_file (optional). object (required for isolate or id_pass). isolate (boolean). id_pass objects|faces. edges (default false). background (hex, r,g,b or "default" for the light grey used by renders). hide_facade (boolean). keep_camera (boolean). antialias (default true; forced off for id passes). transparent (boolean).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            image_path: { type: 'string', description: 'Where to write the PNG.' },
            width: { type: 'integer', minimum: 64, maximum: 8192 },
            height: { type: 'integer', minimum: 64, maximum: 8192 },
            camera: CAMERA_SCHEMA,
            camera_file: { type: 'string' },
            object: { type: 'string' },
            isolate: { type: 'boolean' },
            id_pass: { type: 'string', enum: %w[objects faces] },
            edges: { type: 'boolean' },
            background: { type: 'string' },
            hide_facade: { type: 'boolean' },
            keep_camera: { type: 'boolean' },
            antialias: { type: 'boolean' },
            transparent: { type: 'boolean' }
          },
          required: ['image_path'],
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = { title: TITLE, readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }.freeze

        def parse_arguments(arguments)
          object = text(arguments['object'])
          isolate = boolean(arguments['isolate'], 'isolate') == true
          id_mode = text(arguments['id_pass'])
          if (isolate || id_mode) && object.to_s.strip.empty?
            return invalid('object is required with isolate or id_pass')
          end

          {
            path: required_output_file(arguments, 'image_path'),
            width: integer(arguments['width'], 'width'),
            height: integer(arguments['height'], 'height'),
            camera: camera_from(arguments),
            isolate: isolate ? object : nil,
            id_pass: id_mode ? { 'mode' => id_mode, 'object' => object } : nil,
            edges: boolean(arguments['edges'], 'edges') == true,
            background: text(arguments['background']),
            hide_facade: boolean(arguments['hide_facade'], 'hide_facade') == true,
            keep_camera: boolean(arguments['keep_camera'], 'keep_camera') == true,
            antialias: boolean(arguments['antialias'], 'antialias'),
            transparent: boolean(arguments['transparent'], 'transparent') == true
          }
        end

        def run_on_model(model, parsed)
          Runtime::FacadeCapture.new(model).capture(**parsed.merge(probe: @session.path_probe))
        end
      end
    end
  end
end
