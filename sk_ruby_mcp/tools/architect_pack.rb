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
            PlacePerimeter.new(session: session, attach: attach),
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
          groups_union_m2: { type: 'number' },
          outer_footprint_m2: { type: 'number' },
          coverage_groups: { type: 'number' },
          coverage_union: { type: 'number' },
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
          min_height_m: { type: 'number' },
          courtyard_m: { type: 'array' },
          courtyard_m2: { type: 'number' },
          footprint_m2: { type: 'number' },
          coverage: { type: 'number' },
          depth_m: { type: 'number' },
          height_m: { type: 'number' },
          wings: { type: 'array' },
          overlap_warning: { type: 'boolean' },
          all_storeys: { type: 'boolean' },
          skip_ground: { type: 'boolean' },
          skip_storeys: { type: 'integer' },
          storeys_punched: { type: 'array' },
          targets: { type: 'array' }
        },
        required: ['ok']
      }.freeze

      class ArchitectTool < ModelTool
        def output_schema
          ARCHITECT_OUTPUT_SCHEMA
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

      class PlacePerimeter < ArchitectTool
        NAME = 'place_perimeter'
        TITLE = 'Place a courtyard ring'
        DESCRIPTION = <<~TEXT.strip
          Create four named axis-aligned wings around an open courtyard. Corners are not doubled: long south and north wings take the full site width; east and west fill the gap between them. All sizes are metres. Use this for perimeter housing or office blocks. The reply includes courtyard_m, footprint_m2 (union, no double-counted corners) and coverage against the site rectangle. execute_ruby remains for anything this cannot say.
          Arguments: site_w_m, site_d_m, depth_m, height_m (required metres). origin_m (optional south-west bottom of the site, default [0,0,0]). storeys, tag, color (optional, same as place_box). name_south, name_north, name_east, name_west (optional; defaults "South wing" and so on).
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            site_w_m: { type: 'number', description: 'Site width in metres (X, east).' },
            site_d_m: { type: 'number', description: 'Site depth in metres (Y, north).' },
            depth_m: { type: 'number', description: 'Wing thickness from the street inward, metres.' },
            height_m: { type: 'number', description: 'Wing height in metres.' },
            origin_m: {
              type: 'array',
              items: { type: 'number' },
              minItems: 3,
              maxItems: 3,
              description: 'South-west bottom corner of the site in metres. Default [0,0,0].'
            },
            storeys: { type: 'integer', minimum: 1, description: 'Split each wing into this many stacked floor groups.' },
            tag: { type: 'string', description: 'SketchUp tag/layer name.' },
            color: { type: 'string', description: 'Hex #RRGGBB or r,g,b 0-255.' },
            name_south: { type: 'string' },
            name_north: { type: 'string' },
            name_east: { type: 'string' },
            name_west: { type: 'string' }
          },
          required: %w[site_w_m site_d_m depth_m height_m],
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
          site_w = number(arguments['site_w_m'], 'site_w_m')
          site_d = number(arguments['site_d_m'], 'site_d_m')
          depth = number(arguments['depth_m'], 'depth_m')
          height = number(arguments['height_m'], 'height_m')
          if [site_w, site_d, depth, height].any?(&:nil?)
            return invalid('site_w_m, site_d_m, depth_m and height_m are required positive metres')
          end
          if [site_w, site_d, depth, height].any? { |n| n <= 0.0 }
            return invalid('site_w_m, site_d_m, depth_m and height_m must be positive')
          end

          storeys = integer(arguments['storeys'], 'storeys')
          return invalid('storeys must be >= 1') if !storeys.nil? && storeys < 1

          names = {
            'south' => text(arguments['name_south']),
            'north' => text(arguments['name_north']),
            'east' => text(arguments['name_east']),
            'west' => text(arguments['name_west'])
          }
          names.delete_if { |_key, value| value.nil? || value.to_s.empty? }
          {
            origin_m: vec3(arguments['origin_m'], 'origin_m') || [0.0, 0.0, 0.0],
            site_w_m: site_w,
            site_d_m: site_d,
            depth_m: depth,
            height_m: height,
            names: names,
            tag: text(arguments['tag']),
            color: arguments['color'],
            storeys: storeys
          }
        end

        def run_on_model(model, parsed)
          with_operation(model, 'MCP place_perimeter') do
            Runtime::ArchitectOps.new(model).place_perimeter(**parsed)
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
          Report footprint, coverage against a given site, and a crude GFA (top-level group XY × guessed storeys). groups_footprint_m2 sums top-level axis-aligned XY boxes and can double-count overlapping corners. groups_union_m2 is the XY union of those boxes (correct for an L or U of overlapping bars). Groups shorter than min_height_m (default 1.0 m) are skipped so site plates and lawns do not inflate coverage. outer_footprint_m2 is the model bounding rectangle. Pass site_w_m and site_d_m or site_area_m2. Does not change the model.
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
          Punch a regular grid of rectangular holes in the largest vertical façade of a named group that faces north, south, east or west (SketchUp: Y north, X east, Z up). Holes are inner loops on the wall face, not cutting-components. Use this for windows. sill_m is the height of the first row from the bottom of the face; leftover height is split between rows and above the last row, not below the first.           If all_storeys is true, punch nested floor groups inside the named parent (Этаж 01, Этаж 02, …) instead of one tall face; skip_ground drops the lowest floor; skip_storeys drops that many lowest floors (skip_ground is skip_storeys=1). Typical per-floor rows=1. execute_ruby if you need irregular openings or several façades.
          Arguments: group_name (required; group name or nested path such as South wing/Этаж 02). facing (required: north/south/east/west). cols, rows (required integers). width_m, height_m (required metres). sill_m (optional, default 0.9, from the bottom of the face). margin_m (optional, default 0.4). all_storeys (optional boolean). skip_ground (optional boolean, only with all_storeys). skip_storeys (optional integer >= 0, only with all_storeys). The reply includes first_sill_m, last_head_m and storeys_punched.
        TEXT
        INPUT_SCHEMA = {
          type: 'object',
          properties: {
            group_name: { type: 'string', description: 'Group name or nested path (South wing/Этаж 02).' },
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
            margin_m: { type: 'number', description: 'Keep-out from the face edges in metres (default 0.4).' },
            all_storeys: {
              type: 'boolean',
              description: 'Punch nested floor groups inside the named parent instead of one tall face.'
            },
            skip_ground: {
              type: 'boolean',
              description: 'With all_storeys, skip the lowest floor group (same as skip_storeys=1).'
            },
            skip_storeys: {
              type: 'integer',
              minimum: 0,
              description: 'With all_storeys, skip this many lowest floor groups (e.g. 2 to leave two floors blank).'
            }
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
          skip_n = integer(arguments['skip_storeys'], 'skip_storeys')
          return invalid('skip_storeys must be >= 0') if !skip_n.nil? && skip_n < 0

          skip_ground = boolean(arguments['skip_ground'], 'skip_ground') == true
          skip_n = 1 if skip_n.nil? && skip_ground
          skip_n = 0 if skip_n.nil?
          {
            group_name: group_name,
            facing: facing,
            cols: cols,
            rows: rows,
            width_m: width_m,
            height_m: height_m,
            sill_m: sill.nil? ? 0.9 : sill,
            margin_m: margin.nil? ? 0.4 : margin,
            all_storeys: boolean(arguments['all_storeys'], 'all_storeys') == true,
            skip_ground: skip_n >= 1,
            skip_storeys: skip_n
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
