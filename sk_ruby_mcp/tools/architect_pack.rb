# frozen_string_literal: true

module SkRubyMcp
  module Tools
    # Именованные инструменты масс и проёмов. Включаются файлом architect_pack.on в корне расширения.
    module ArchitectPack
      FLAG_NAME = 'architect_pack.on'

      class << self
        attr_writer :flag_path

        def flag_path
          @flag_path || File.expand_path('../../architect_pack.on', __dir__)
        end

        def enabled?
          File.file?(flag_path)
        end

        def instances(session:, attach:)
          [
            PlaceBox.new(session: session, attach: attach),
            ListGroups.new(session: session, attach: attach),
            SiteMetrics.new(session: session, attach: attach),
            GridOpenings.new(session: session, attach: attach)
          ]
        end
      end

      ARCHITECT_OUTPUT_SCHEMA = {
        type: 'object',
        properties: {
          ok: { type: 'boolean' },
          error: { type: 'string' },
          message: { type: 'string' },
          retry: { type: 'boolean' },
          instead: { type: 'string' },
          next: { type: 'string' },
          path: { type: %w[string null] },
          name: { type: 'string' },
          storeys: { type: 'integer' },
          storey_names: { type: 'array' },
          origin_m: { type: 'array' },
          size_m: { type: 'array' },
          tag: { type: 'string' },
          bounds_m: { type: 'object' },
          count: { type: 'integer' },
          truncated: { type: 'boolean' },
          groups: { type: 'array' },
          site_w_m: { type: 'number' },
          site_d_m: { type: 'number' },
          site_area_m2: { type: 'number' },
          storey_h_m: { type: 'number' },
          groups_footprint_m2: { type: 'number' },
          outer_footprint_m2: { type: 'number' },
          coverage_groups: { type: 'number' },
          coverage_outer: { type: 'number' },
          gfa_m2: { type: 'number' },
          group: { type: 'string' },
          facing: { type: 'string' },
          requested: { type: 'integer' },
          placed: { type: 'integer' },
          skipped: { type: 'integer' },
          face_width_m: { type: 'number' },
          face_height_m: { type: 'number' },
          gap_u_m: { type: 'number' },
          gap_v_m: { type: 'number' },
          first_sill_m: { type: 'number' },
          last_head_m: { type: 'number' },
          min_height_m: { type: 'number' }
        },
        required: ['ok']
      }.freeze

      class ArchitectTool
        POLLS_WHILE_BUSY = false

        def initialize(session:, attach:)
          raise ArgumentError, 'session is required' if session.nil?
          raise ArgumentError, 'attach is required' if attach.nil?

          @session = session
          @attach = attach
        end

        def name
          self.class::NAME
        end

        def polls_while_busy?
          false
        end

        def spec
          {
            name: self.class::NAME,
            title: self.class::TITLE,
            description: self.class::DESCRIPTION,
            inputSchema: self.class::INPUT_SCHEMA,
            outputSchema: ARCHITECT_OUTPUT_SCHEMA,
            annotations: self.class::ANNOTATIONS
          }
        end

        def call(arguments)
          arguments = {} unless arguments.is_a?(Hash)
          unknown = ArgumentGuard.unknown_message(arguments, self.class::ALLOWED_KEYS)
          if unknown
            return ToolReply.call(
              ok: false,
              error: 'unknown_arguments',
              message: unknown,
              retry: false,
              next: 'Pass only the documented arguments.'
            )
          end

          if (refusal = @session.ruby_refusal)
            return ToolReply.call(
              ok: false,
              error: refusal[:class],
              message: refusal[:message],
              retry: true,
              instead: 'model_status',
              next: refusal[:next]
            )
          end

          status = @session.status
          unless status.ok && status.state == 'active'
            return ToolReply.call(
              ok: false,
              error: status.code || 'no_document',
              message: status.message || 'No focused document. Call model_new or model_open.',
              retry: true,
              instead: 'model_status',
              next: status.next || @session.empty_document_next
            )
          end

          model = @attach.current_model
          if model.nil? || (model.respond_to?(:valid?) && !model.valid?)
            return ToolReply.call(
              ok: false,
              error: 'no_document',
              message: 'No focused document. Call model_new or model_open.',
              retry: true,
              instead: 'model_status',
              next: @session.empty_document_next
            )
          end

          parsed = parse_arguments(arguments)
          return parsed if parsed.is_a?(Hash) && parsed[:content]

          payload = run_on_model(model, parsed)
          ToolReply.call(payload)
        rescue ArgumentError => error
          ToolReply.call(
            ok: false,
            error: 'unknown_arguments',
            message: error.message,
            retry: false,
            next: 'Pass only the documented arguments.'
          )
        rescue StandardError, ScriptError => error
          ToolReply.call(
            ok: false,
            error: 'ruby_error',
            message: "#{error.class}: #{error.message}",
            retry: true,
            instead: 'model_status'
          )
        end

        private

        def invalid(message)
          ToolReply.call(
            ok: false,
            error: 'unknown_arguments',
            message: message,
            retry: false,
            next: 'Pass only the documented arguments.'
          )
        end

        def vec3(value, name)
          return nil if value.nil?
          unless value.is_a?(Array) && value.size == 3 && value.all? { |item| item.is_a?(Numeric) }
            raise ArgumentError, "#{name} must be [x, y, z] numbers in metres"
          end

          value.map(&:to_f)
        end

        def number(value, name)
          return nil if value.nil?
          raise ArgumentError, "#{name} must be a number" unless value.is_a?(Numeric)

          value.to_f
        end

        def integer(value, name)
          return nil if value.nil?
          unless value.is_a?(Integer) || (value.is_a?(Numeric) && value == value.to_i)
            raise ArgumentError, "#{name} must be an integer"
          end

          value.to_i
        end

        def text(value)
          value.nil? ? nil : value.to_s
        end

        def with_operation(model, label)
          committed = false
          model.start_operation(label, true) if model.respond_to?(:start_operation)
          result = yield
          if model.respond_to?(:commit_operation)
            model.commit_operation
            committed = true
          end
          view = model.active_view if model.respond_to?(:active_view)
          view.invalidate if view.respond_to?(:invalidate)
          result
        ensure
          if !committed && model.respond_to?(:abort_operation)
            begin
              model.abort_operation
            rescue StandardError, ScriptError
              nil
            end
          end
        end
      end

      class PlaceBox < ArchitectTool
        NAME = 'place_box'
        TITLE = 'Place a metre box'
        DESCRIPTION = <<~TEXT.strip
          Create an axis-aligned box in metres as a named group. Origin is the south-west bottom corner (X east, Y north, Z up). size_m is [dx, dy, dz] in metres. Use this for massing: slabs, podiums, wings, towers. Optional storeys splits the height into stacked named floor groups. Optional tag (SketchUp tag/layer) and color (#RRGGBB or r,g,b). execute_ruby remains available for anything this cannot say.
          Arguments: size_m (required [dx,dy,dz] metres). origin_m (optional [x,y,z], default [0,0,0]). name (optional). storeys (optional integer >= 1). tag (optional string). color (optional hex or "r,g,b").
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            size_m: {
              type: 'array',
              items: { type: 'number' },
              minItems: 3,
              maxItems: 3,
              description: 'Box size in metres [dx, dy, dz].'
            },
            origin_m: {
              type: 'array',
              items: { type: 'number' },
              minItems: 3,
              maxItems: 3,
              description: 'South-west bottom corner in metres. Default [0,0,0].'
            },
            name: { type: 'string', description: 'Group name.' },
            storeys: { type: 'integer', minimum: 1, description: 'Split height into this many stacked floor groups.' },
            tag: { type: 'string', description: 'SketchUp tag/layer name.' },
            color: { type: 'string', description: 'Hex #RRGGBB or r,g,b 0-255.' }
          },
          required: ['size_m'],
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = {
          title: TITLE,
          readOnlyHint: false,
          destructiveHint: true,
          idempotentHint: false,
          openWorldHint: false
        }.freeze

        def parse_arguments(arguments)
          size = vec3(arguments['size_m'], 'size_m')
          return invalid('size_m is required [dx, dy, dz] in metres') if size.nil?
          return invalid('size_m values must be positive') if size.any? { |n| n <= 0.0 }

          origin = vec3(arguments['origin_m'], 'origin_m') || [0.0, 0.0, 0.0]
          storeys = integer(arguments['storeys'], 'storeys')
          return invalid('storeys must be >= 1') if !storeys.nil? && storeys < 1

          {
            origin_m: origin,
            size_m: size,
            name: text(arguments['name']),
            tag: text(arguments['tag']),
            color: arguments['color'],
            storeys: storeys
          }
        end

        def run_on_model(model, parsed)
          with_operation(model, 'MCP place_box') do
            Runtime::ArchitectOps.new(model).place_box(**parsed)
          end
        end
      end

      class ListGroups < ArchitectTool
        NAME = 'list_groups'
        TITLE = 'List nested groups'
        DESCRIPTION = <<~TEXT.strip
          List groups and component instances in the focused model with nested names, depth, tag, face count and bounds in metres. Use this when model_status is too shallow (it only shows 20 top-level objects). Does not change the model.
          Arguments: max_depth (optional integer 1..16, default 8). max_items (optional integer 1..400, default 120).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            max_depth: { type: 'integer', minimum: 1, maximum: 16, description: 'Nesting depth to walk (default 8).' },
            max_items: { type: 'integer', minimum: 1, maximum: 400, description: 'Maximum rows (default 120).' }
          },
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = {
          title: TITLE,
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false
        }.freeze

        def parse_arguments(arguments)
          {
            max_depth: integer(arguments['max_depth'], 'max_depth'),
            max_items: integer(arguments['max_items'], 'max_items')
          }
        end

        def run_on_model(model, parsed)
          Runtime::ArchitectOps.new(model).list_groups(
            max_depth: parsed[:max_depth],
            max_items: parsed[:max_items]
          )
        end
      end

      class SiteMetrics < ArchitectTool
        NAME = 'site_metrics'
        TITLE = 'Site coverage and GFA'
        DESCRIPTION = <<~TEXT.strip
          Report footprint, coverage against a given site, and a crude GFA (top-level group XY × guessed storeys). groups_footprint_m2 sums top-level axis-aligned XY boxes and can double-count overlapping corners. Groups shorter than min_height_m (default 1.0 m) are skipped so site plates and lawns do not inflate coverage. outer_footprint_m2 is the model bounding rectangle. Pass site_w_m and site_d_m or site_area_m2. Does not change the model.
          Arguments: site_w_m, site_d_m (optional metres). site_area_m2 (optional). storey_h_m (optional, default 3.3). min_height_m (optional, default 1.0).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            site_w_m: { type: 'number', description: 'Site width in metres (X).' },
            site_d_m: { type: 'number', description: 'Site depth in metres (Y).' },
            site_area_m2: { type: 'number', description: 'Site area in square metres, if not width×depth.' },
            storey_h_m: { type: 'number', description: 'Typical storey height for GFA guess (default 3.3).' },
            min_height_m: { type: 'number', description: 'Ignore top-level groups shorter than this (default 1.0 m).' }
          },
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = {
          title: TITLE,
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false
        }.freeze

        def parse_arguments(arguments)
          {
            site_w_m: number(arguments['site_w_m'], 'site_w_m'),
            site_d_m: number(arguments['site_d_m'], 'site_d_m'),
            site_area_m2: number(arguments['site_area_m2'], 'site_area_m2'),
            storey_h_m: number(arguments['storey_h_m'], 'storey_h_m'),
            min_height_m: number(arguments['min_height_m'], 'min_height_m')
          }
        end

        def run_on_model(model, parsed)
          Runtime::ArchitectOps.new(model).site_metrics(**parsed)
        end
      end

      class GridOpenings < ArchitectTool
        NAME = 'grid_openings'
        TITLE = 'Punch a façade grid'
        DESCRIPTION = <<~TEXT.strip
          Punch a regular grid of rectangular holes in the largest vertical façade of a named group that faces north, south, east or west (SketchUp: Y north, X east, Z up). Holes are inner loops on the wall face, not cutting-components. Use this for windows. sill_m is the height of the first row from the bottom of the face; leftover height is split between rows and above the last row, not below the first. execute_ruby if you need irregular openings or several façades.
          Arguments: group_name (required). facing (required: north/south/east/west). cols, rows (required integers). width_m, height_m (required metres). sill_m (optional, default 0.9, from the bottom of the face). margin_m (optional, default 0.4). The reply includes first_sill_m and last_head_m.
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            group_name: { type: 'string', description: 'Name of the group whose façade to punch.' },
            facing: {
              type: 'string',
              enum: %w[north south east west n s e w],
              description: 'World direction of the façade.'
            },
            cols: { type: 'integer', minimum: 1, description: 'Windows across.' },
            rows: { type: 'integer', minimum: 1, description: 'Windows up.' },
            width_m: { type: 'number', description: 'Opening width in metres.' },
            height_m: { type: 'number', description: 'Opening height in metres.' },
            sill_m: { type: 'number', description: 'Sill height from the bottom of the face in metres (default 0.9).' },
            margin_m: { type: 'number', description: 'Keep-out from the face edges in metres (default 0.4).' }
          },
          required: %w[group_name facing cols rows width_m height_m],
          additionalProperties: false
        }.freeze
        ALLOWED_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze
        ANNOTATIONS = {
          title: TITLE,
          readOnlyHint: false,
          destructiveHint: true,
          idempotentHint: false,
          openWorldHint: false
        }.freeze

        def parse_arguments(arguments)
          group_name = text(arguments['group_name'])
          facing = text(arguments['facing'])
          return invalid('group_name is required') if group_name.to_s.empty?
          return invalid('facing must be north, south, east or west') if Runtime::ArchitectMath.facing_vector(facing).nil?

          cols = integer(arguments['cols'], 'cols')
          rows = integer(arguments['rows'], 'rows')
          width_m = number(arguments['width_m'], 'width_m')
          height_m = number(arguments['height_m'], 'height_m')
          return invalid('cols, rows, width_m and height_m are required') if cols.nil? || rows.nil? || width_m.nil? || height_m.nil?

          sill = number(arguments['sill_m'], 'sill_m')
          margin = number(arguments['margin_m'], 'margin_m')
          {
            group_name: group_name,
            facing: facing,
            cols: cols,
            rows: rows,
            width_m: width_m,
            height_m: height_m,
            sill_m: sill.nil? ? 0.9 : sill,
            margin_m: margin.nil? ? 0.4 : margin
          }
        end

        def run_on_model(model, parsed)
          with_operation(model, 'MCP grid_openings') do
            Runtime::ArchitectOps.new(model).grid_openings(**parsed)
          end
        end
      end
    end
  end
end
