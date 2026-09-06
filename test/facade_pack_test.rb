# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'schema_check'
require 'tmpdir'

# Заглушки сцены SketchUp: инструмент с гранями, соседняя плита перекрытия, определения и материалы.
class FacadePackTest < Minitest::Test
  Pack = SkRubyMcp::Tools::FacadePack
  SessionResult = SkRubyMcp::Runtime::SessionResult
  ModelSnapshot = SkRubyMcp::Runtime::ModelSnapshot
  IN = SkRubyMcp::Runtime::ArchitectMath::INCHES_PER_M

  class FakePoint
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def transform(_tr)
      self
    end
  end

  class FakeBounds
    attr_reader :min, :max

    def initialize(min, max)
      @min = min
      @max = max
    end

    def corner(index)
      FakePoint.new(
        (index & 1).zero? ? @min.x : @max.x,
        (index & 2).zero? ? @min.y : @max.y,
        (index & 4).zero? ? @min.z : @max.z
      )
    end
  end

  class FakeAttributes
    def initialize
      @dicts = {}
    end

    def set_attribute(dict, key, value)
      (@dicts[dict] ||= {})[key] = value
    end

    def get_attribute(dict, key, default = nil)
      (@dicts[dict] || {}).fetch(key, default)
    end
  end

  class FakeFace < FakeAttributes
    attr_reader :vertices, :parent
    attr_accessor :material, :back_material, :normal, :persistent_id

    @@next_id = 100

    def initialize(points, normal, parent, entities = nil)
      super()
      @vertices = points
      @normal = normal
      @parent = parent
      @home = entities
      @deleted = false
      @persistent_id = (@@next_id += 1)
    end

    def valid?
      !@deleted
    end

    def reverse!
      @normal = FakePoint.new(-@normal.x, -@normal.y, -@normal.z)
      self
    end

    def erase!
      @deleted = true
      @home&.remove(self)
    end

    # Как SketchUp: исходная грань остаётся, появляются дальняя грань с обратной нормалью и боковые грани.
    def pushpull(distance)
      return if @home.nil?

      shift = FakePoint.new(@normal.x * distance, @normal.y * distance, @normal.z * distance)
      far_points = @vertices.map { |pt| FakePoint.new(pt.x + shift.x, pt.y + shift.y, pt.z + shift.z) }
      far = FakeFace.new(far_points, FakePoint.new(-@normal.x, -@normal.y, -@normal.z), @parent, @home)
      @home.items << far
      @vertices.each_with_index do |pt, index|
        nxt = @vertices[(index + 1) % @vertices.length]
        side = FakeFace.new([pt, nxt, far_points[(index + 1) % @vertices.length], far_points[index]], FakePoint.new(1, 0, 0), @parent, @home)
        @home.items << side
      end
    end
  end

  class FakeEntities
    attr_reader :items, :owner

    def initialize(owner)
      @owner = owner
      @items = []
    end

    def to_a
      @items.dup
    end

    def add_face(*pts)
      pts = pts.first if pts.size == 1 && pts.first.is_a?(Array)
      points = pts.map { |pt| pt.is_a?(Array) ? FakePoint.new(*pt) : pt }
      face = FakeFace.new(points, FakePoint.new(0, 0, 1), @owner, self)
      @items << face
      face
    end

    def add_instance(definition, transformation)
      instance = FakeInstance.new('', definition, self)
      instance.transformation = transformation
      @items << instance
      instance
    end

    def add_group
      group = FakeGroup.new(self)
      @items << group
      group
    end

    def remove(item)
      @items.delete(item)
    end
  end

  class FakeBehavior
    attr_accessor :is2d, :cuts_opening, :snapto
  end

  class FakeDefinition < FakeAttributes
    attr_reader :entities, :behavior, :name
    attr_accessor :instances

    def initialize(name)
      super()
      @name = name
      @entities = FakeEntities.new(self)
      @behavior = FakeBehavior.new
      @instances = []
    end

    def count_instances
      @instances.length
    end
  end

  class FakeDefinitions
    include Enumerable

    def initialize
      @list = []
    end

    def add(name)
      definition = FakeDefinition.new(name)
      @list << definition
      definition
    end

    def each(&block)
      @list.each(&block)
    end
  end

  class FakeInstance < FakeAttributes
    attr_accessor :name, :transformation, :material, :hidden, :glued_to, :bounds_override
    attr_reader :definition, :parent_entities, :persistent_id

    @@next_id = 5000

    def initialize(name, definition, parent_entities)
      super()
      @name = name
      @definition = definition
      @parent_entities = parent_entities
      @transformation = :identity
      @hidden = false
      @deleted = false
      @persistent_id = (@@next_id += 1)
      definition.instances << self
    end

    def parent
      @parent_entities.owner
    end

    def hidden?
      @hidden
    end

    def valid?
      !@deleted
    end

    def deleted?
      @deleted
    end

    def erase!
      @deleted = true
      @parent_entities.remove(self)
    end

    def bounds
      return @bounds_override if @bounds_override

      points = []
      @definition.entities.items.each do |item|
        points.concat(item.vertices) if item.respond_to?(:vertices)
      end
      return FakeBounds.new(FakePoint.new(0, 0, 0), FakePoint.new(0, 0, 0)) if points.empty?

      FakeBounds.new(
        FakePoint.new(points.map(&:x).min, points.map(&:y).min, points.map(&:z).min),
        FakePoint.new(points.map(&:x).max, points.map(&:y).max, points.map(&:z).max)
      )
    end
  end

  class FakeGroup < FakeAttributes
    attr_accessor :name, :material, :hidden
    attr_reader :entities, :transformation, :parent_entities, :persistent_id

    @@next_id = 9000

    def initialize(parent_entities)
      super()
      @parent_entities = parent_entities
      @entities = FakeEntities.new(self)
      @transformation = :identity
      @name = ''
      @hidden = false
      @deleted = false
      @persistent_id = (@@next_id += 1)
    end

    def hidden?
      @hidden
    end

    def valid?
      !@deleted
    end

    def deleted?
      @deleted
    end

    def erase!
      @deleted = true
      @parent_entities.remove(self)
    end

    def bounds
      FakeBounds.new(FakePoint.new(0, 0, 0), FakePoint.new(0, 0, 0))
    end
  end

  class FakeMaterial
    attr_accessor :name, :color

    def initialize(name)
      @name = name
    end
  end

  class FakeMaterials
    def initialize
      @by_name = {}
    end

    def [](name)
      @by_name[name]
    end

    def add(name)
      @by_name[name] = FakeMaterial.new(name)
    end

    def remove(material)
      @by_name.delete(material.name)
    end
  end

  class FakeModel
    attr_reader :entities, :definitions, :materials, :events
    attr_accessor :path, :active_view

    def initialize
      @entities = FakeEntities.new(self)
      @definitions = FakeDefinitions.new
      @materials = FakeMaterials.new
      @events = []
      @path = '/tmp/facade.skp'
      @active_view = nil
    end

    def active_entities
      @entities
    end

    def valid?
      true
    end

    def start_operation(name, disable_ui = false, *_rest)
      @events << [:start, name, disable_ui]
      true
    end

    def commit_operation
      @events << [:commit]
      true
    end

    def abort_operation
      @events << [:abort]
      true
    end
  end

  class FakeAttach
    def initialize(model)
      @model = model
    end

    def current_model
      @model
    end
  end

  class FakeSession
    def ruby_refusal
      nil
    end

    def status
      SessionResult.new(ok: true, state: 'active', snapshot: ModelSnapshot.new(path: nil, title: 'Untitled', modified: true, faces: 0))
    end

    def empty_document_next
      SkRubyMcp::Runtime::DocumentSession::NEXT_WHEN_EMPTY
    end
  end

  def m(value)
    value * IN
  end

  # Башня 20×10×10 м: южная грань (нормаль -Y), крыша (нормаль +Z); плита на 3.3 м рядом.
  def setup
    @model = FakeModel.new
    tower_def = @model.definitions.add('Tower def')
    @south = tower_def.entities.add_face(
      FakePoint.new(0, 0, 0), FakePoint.new(m(20), 0, 0), FakePoint.new(m(20), 0, m(10)), FakePoint.new(0, 0, m(10))
    )
    @south.normal = FakePoint.new(0, -1, 0)
    roof = tower_def.entities.add_face(
      FakePoint.new(0, 0, m(10)), FakePoint.new(m(20), 0, m(10)), FakePoint.new(m(20), m(10), m(10)), FakePoint.new(0, m(10), m(10))
    )
    roof.normal = FakePoint.new(0, 0, 1)
    @tower = FakeInstance.new('Tower', tower_def, @model.entities)
    @model.entities.items << @tower
    plate_def = @model.definitions.add('Plate def')
    @plate = FakeInstance.new('Mass Floor', plate_def, @model.entities)
    @plate.bounds_override = FakeBounds.new(FakePoint.new(0, 0, m(3.3)), FakePoint.new(m(20), m(10), m(3.3)))
    @model.entities.items << @plate
    @session = FakeSession.new
    @attach = FakeAttach.new(@model)
  end

  def tool(klass)
    klass.new(session: @session, attach: @attach)
  end

  def parsed(result)
    JSON.parse(result[:content].first[:text])
  end

  def schedule
    [{ 'face' => @south.persistent_id, 'kind' => 'small_window', 'x0' => 0.1, 'x1' => 0.9, 'count' => 3, 'width_m' => 1.5, 'storey' => 1 }]
  end

  def test_flag_defaults_off_and_follows_the_file
    previous = Pack.flag_path
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'facade_pack.on')
      Pack.flag_path = path
      refute Pack.enabled?
      File.write(path, "on\n")
      assert Pack.enabled?
    end
  ensure
    Pack.flag_path = previous
  end

  def test_instances_lists_eight_tools_with_valid_specs
    tools = Pack.instances(session: @session, attach: @attach)
    assert_equal %w[facade_faces facade_place_openings facade_place_bands facade_paint facade_list facade_remove facade_verify facade_capture], tools.map(&:name)
    tools.each do |item|
      spec = item.spec
      assert_equal 'object', spec[:inputSchema][:type]
      assert spec[:description].length > 80, "#{item.name} needs a real description"
      assert SchemaCheck.valid?(spec[:outputSchema], 'ok' => true, 'object' => 'Tower', 'count' => 1)
      assert_includes [true, false], spec[:annotations][:readOnlyHint]
    end
  end

  def test_unknown_arguments_are_rejected
    result = tool(Pack::Faces).call('object' => 'Tower', 'bogus' => 1)
    assert result[:isError]
    assert_equal 'unknown_arguments', parsed(result)['error']
  end

  def test_faces_lists_vertical_faces_with_storeys
    body = parsed(tool(Pack::Faces).call('object' => 'Tower'))
    assert_equal true, body['ok'], body.inspect
    assert_equal 1, body['count']
    face = body['faces'].first
    assert_equal @south.persistent_id, face['id']
    assert_in_delta 20.0, face['width_m'], 1e-3
    assert_in_delta 10.0, face['height_m'], 1e-3
    assert_equal false, face['flipped']
    assert_in_delta 1.0, face['normal'][1].abs, 1e-6
    assert_equal [3.3], body['storeys_m']
    assert_equal [[0.0, 3.3], [3.3, 10.0]], body['storey_cells'].map { |c| [c['z0_m'], c['z1_m']] }
    assert_equal 1, body['shared_definition']
    assert_nil face['pixel_quad']
  end

  def test_faces_projects_pixel_quads_with_an_explicit_camera
    body = parsed(tool(Pack::Faces).call(
      'object' => 'Tower',
      'camera' => { 'eye_m' => [10.0, -60.0, 5.0], 'target_m' => [10.0, 0.0, 5.0], 'up' => [0, 0, 1], 'fov_deg' => 30.0 },
      'image_width' => 1600,
      'image_height' => 1000
    ))
    assert_equal true, body['ok'], body.inspect
    quad = body['faces'].first['pixel_quad']
    assert_equal 4, quad.length
    assert quad[0][0] < quad[1][0], 'bottom-left is left of bottom-right'
    assert quad[0][1] > quad[3][1], 'bottom-left is below top-left'
    assert_in_delta 800.0, body['faces'].first['center_px'][0], 1.0
    assert_equal({ 'width' => 1600, 'height' => 1000 }, body['image'])
  end

  def test_faces_write_to_saves_the_same_reply_as_json
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'faces', 'tower.json')
      Dir.mkdir(File.dirname(path))
      body = parsed(tool(Pack::Faces).call('object' => 'Tower', 'write_to' => path))
      assert_equal true, body['ok'], body.inspect
      assert_equal path, body['written']
      saved = JSON.parse(File.read(path))
      assert_equal body['faces'], saved['faces']
      assert_equal body['storey_cells'], saved['storey_cells']
      refute saved.key?('written')

      missing_dir = parsed(tool(Pack::Faces).call('object' => 'Tower', 'write_to' => File.join(dir, 'nope', 'x.json')))
      assert_equal true, missing_dir['ok']
      assert_nil missing_dir['written']
      assert_match(/Errno::ENOENT/, missing_dir['write_error'])
    end
  end

  def test_faces_reports_missing_object_with_available_names
    body = parsed(tool(Pack::Faces).call('object' => 'Nope'))
    assert_equal 'object_not_found', body['error']
    assert_includes body['message'], 'Tower'
  end

  def test_place_list_verify_and_remove_round_trip
    placed = parsed(tool(Pack::PlaceOpenings).call('object' => 'Tower', 'items' => schedule))
    assert_equal true, placed['ok'], placed.inspect
    assert_equal 3, placed['placed']
    assert_in_delta 4.875, placed['items'][0]['u0_m'], 1e-3
    assert_in_delta 9.25, placed['items'][1]['u0_m'], 1e-3
    assert_in_delta 3.3 + (0.25 * 6.7), placed['items'][0]['z0_m'], 1e-3
    assert_in_delta 10.0, placed['items'][0]['z1_m'], 1e-3
    assert_includes @model.events, [:start, 'MCP facade_place_openings', true]
    assert_includes @model.events, [:commit]

    definition = @model.definitions.find { |d| d.get_attribute(SkRubyMcp::Runtime::FacadeOps::DICT, 'role') == 'opening_definition' }
    refute_nil definition
    assert_equal true, definition.behavior.is2d
    assert_equal true, definition.behavior.cuts_opening
    assert_equal 1, @model.definitions.count { |d| d.get_attribute(SkRubyMcp::Runtime::FacadeOps::DICT, 'role') == 'opening_definition' }, 'identical openings share one definition'

    listed = parsed(tool(Pack::List).call('object' => 'Tower'))
    assert_equal 3, listed['openings']
    assert_equal 'small_window', listed['items'].first['kind']
    assert_equal @south.persistent_id.to_s, listed['items'].first['face']
    assert_equal true, listed['items'].first['glued']

    verified = parsed(tool(Pack::Verify).call('object' => 'Tower', 'items' => schedule))
    assert_equal true, verified['ok'], verified.inspect
    assert_equal 3, verified['matched']

    shifted = schedule.map { |item| item.merge('x0' => 0.2) }
    drift = parsed(tool(Pack::Verify).call('object' => 'Tower', 'items' => shifted))
    assert_equal false, drift['ok']
    assert drift['mismatched'].length + drift['missing'].length + drift['extra'].length > 0

    faces_after = parsed(tool(Pack::Faces).call('object' => 'Tower'))
    assert_equal 1, faces_after['count'], 'opening component faces are not host faces'

    removed = parsed(tool(Pack::Remove).call('object' => 'Tower', 'role' => 'opening'))
    assert_equal 3, removed['removed']
    assert_equal 0, parsed(tool(Pack::List).call('object' => 'Tower'))['count']
  end

  def test_replace_removes_openings_on_touched_faces
    tool(Pack::PlaceOpenings).call('object' => 'Tower', 'items' => schedule)
    again = parsed(tool(Pack::PlaceOpenings).call('object' => 'Tower', 'items' => schedule, 'replace' => true))
    assert_equal 3, again['placed']
    assert_equal 3, parsed(tool(Pack::List).call('object' => 'Tower'))['openings']
  end

  def test_place_reports_schedule_errors_per_item
    body = parsed(tool(Pack::PlaceOpenings).call(
      'object' => 'Tower',
      'items' => [
        { 'face' => @south.persistent_id, 'x0' => 0.1, 'x1' => 0.2, 'storey' => 9 },
        { 'face' => 424_242, 'x0' => 0.1, 'x1' => 0.2, 'storey' => 0 },
        { 'face' => @south.persistent_id, 'kind' => 'glass_door', 'x0' => 0.4, 'x1' => 0.5, 'storey' => 0 }
      ]
    ))
    assert_equal false, body['ok']
    assert_equal 1, body['placed']
    assert_equal 2, body['failed']
    errors = body['items'].reject { |row| row['ok'] }.map { |row| row['error'] }
    assert errors.any? { |e| e.include?('storey 9') }
    assert errors.any? { |e| e.include?('424242') }
  end

  def test_opening_definition_has_an_open_hole_and_an_outward_glass_pane
    body = parsed(tool(Pack::PlaceOpenings).call('object' => 'Tower', 'items' => [{ 'face' => @south.persistent_id, 'x0' => 0.1, 'x1' => 0.3, 'storey' => 1, 'mullions' => 1 }]))
    assert_equal 1, body['placed'], body.inspect
    definition = @model.definitions.find { |item| item.get_attribute(SkRubyMcp::Runtime::FacadeScene::DICT, 'role') == 'opening_definition' }
    refute_nil definition
    faces = definition.entities.items.select { |item| item.is_a?(FakeFace) && item.valid? }
    recess_in = SkRubyMcp::Runtime::FacadeMath::OPENING_DEFAULTS['recess_m'] * IN
    z_of = ->(face) { face.vertices.map { |pt| pt.z.round(3) }.uniq }
    lids = faces.select { |face| z_of.call(face) == [0.0] }
    assert_empty lids, 'the wall-plane lid must be erased so the hole shows the pane'
    panes = faces.select { |face| z_of.call(face) == [(-recess_in).round(3)] }
    assert_equal 1, panes.length
    assert panes.first.normal.z.positive?, 'the pane faces out of the wall'
    assert_match(/MCP glass/, panes.first.material.name)
    reveals = faces.select { |face| z_of.call(face).sort == [(-recess_in).round(3), 0.0] }
    assert_equal 4, reveals.length
    reveals.each { |face| assert_match(/MCP frame/, face.material.name) }
    lift = SkRubyMcp::Runtime::FacadeOps::STRIP_LIFT_IN.round(3)
    assert_empty faces.select { |face| z_of.call(face) == [lift] }, 'frame strips leave no face a hair above the wall'
    bar_z = (-recess_in + SkRubyMcp::Runtime::FacadeOps::MULLION_GAP_IN).round(3)
    assert_empty faces.select { |face| z_of.call(face) == [bar_z] }, 'mullions leave no start face on the pane side'
    frame_out = SkRubyMcp::Runtime::FacadeMath::OPENING_DEFAULTS['frame_out_m'] * IN
    proud = faces.select { |face| z_of.call(face) == [frame_out.round(3)] }
    assert_equal 3, proud.length, 'left, right and bottom frame strips each keep a proud front face'
  end

  def test_overlapping_openings_are_rejected_unless_replaced
    first = parsed(tool(Pack::PlaceOpenings).call(
      'object' => 'Tower',
      'items' => [
        { 'face' => @south.persistent_id, 'x0' => 0.1, 'x1' => 0.3, 'storey' => 1 },
        { 'face' => @south.persistent_id, 'x0' => 0.25, 'x1' => 0.45, 'storey' => 1 },
        { 'face' => @south.persistent_id, 'x0' => 0.3, 'x1' => 0.5, 'storey' => 1 }
      ]
    ))
    assert_equal false, first['ok']
    assert_equal 2, first['placed'], first.inspect
    clash = first['items'].find { |row| !row['ok'] }
    assert_equal 1, clash['item']
    assert_match(/overlaps item 0 column 0 on face/, clash['error'])

    again = parsed(tool(Pack::PlaceOpenings).call('object' => 'Tower', 'items' => [{ 'face' => @south.persistent_id, 'x0' => 0.15, 'x1' => 0.2, 'storey' => 1 }]))
    assert_equal 0, again['placed']
    assert_match(/overlaps existing opening \d+/, again['items'].first['error'])
    assert_equal 2, parsed(tool(Pack::List).call('object' => 'Tower'))['openings']

    replaced = parsed(tool(Pack::PlaceOpenings).call('object' => 'Tower', 'items' => [{ 'face' => @south.persistent_id, 'x0' => 0.15, 'x1' => 0.2, 'storey' => 1 }], 'replace' => true))
    assert_equal 1, replaced['placed']
    assert_equal 1, parsed(tool(Pack::List).call('object' => 'Tower'))['openings']

    tight = parsed(tool(Pack::PlaceOpenings).call('object' => 'Tower', 'items' => [{ 'face' => @south.persistent_id, 'x0' => 0.0, 'x1' => 0.5, 'count' => 3, 'width_m' => 4.0, 'storey' => 0 }]))
    assert_equal 0, tight['placed']
    assert_match(/do not fit into x0..x1/, tight['items'].first['error'])
  end

  def test_place_refuses_shared_definitions
    FakeInstance.new('Tower twin', @tower.definition, @model.entities)
    body = parsed(tool(Pack::PlaceOpenings).call('object' => 'Tower', 'items' => schedule))
    assert_equal 'shared_definition', body['error']
  end

  def test_bands_go_on_vertical_faces_only_and_are_listed
    body = parsed(tool(Pack::PlaceBands).call('object' => 'Tower', 'z_m' => [3.3], 'thickness_m' => 0.4, 'align' => 'center'))
    assert_equal true, body['ok'], body.inspect
    assert_equal 1, body['placed']
    band = body['items'].first
    assert_in_delta 3.1, band['z0_m'], 1e-3
    assert_in_delta 3.5, band['z1_m'], 1e-3
    listed = parsed(tool(Pack::List).call('object' => 'Tower', 'role' => 'band'))
    assert_equal 1, listed['count']
    assert_equal 'band', listed['items'].first['role']
    missing = parsed(tool(Pack::PlaceBands).call('object' => 'Tower', 'z_m' => [3.3], 'faces' => ['12345']))
    assert_equal false, missing['ok']
    assert_equal ['12345'], missing['missing_faces']
  end

  def test_paint_faces_and_clear
    body = parsed(tool(Pack::Paint).call('object' => 'Tower', 'faces' => [@south.persistent_id], 'color' => '#AABBCC'))
    assert_equal true, body['ok'], body.inspect
    assert_equal 1, body['painted']
    assert_equal 'MCP paint AABBCC', body['material']
    assert_equal [170, 187, 204], @south.material.color
    cleared = parsed(tool(Pack::Paint).call('object' => 'Tower', 'faces' => [@south.persistent_id], 'clear' => true))
    assert_equal true, cleared['ok']
    assert_nil @south.material
    whole = parsed(tool(Pack::Paint).call('object' => 'Tower', 'color' => '10,20,30'))
    assert_equal 'MCP paint 0A141E', whole['material']
    assert_equal 'MCP paint 0A141E', @tower.material.name
    nothing = parsed(tool(Pack::Paint).call('object' => 'Tower'))
    assert_equal 'no_material', nothing['error']
  end

  def test_capture_requires_object_for_isolate_and_a_view
    body = parsed(tool(Pack::Capture).call('image_path' => '/tmp/x.png', 'isolate' => true))
    assert_equal 'unknown_arguments', body['error']
    no_view = parsed(tool(Pack::Capture).call('image_path' => '/tmp/x.png'))
    assert_equal 'capture_failed', no_view['error']
  end

  def test_color_table_sits_next_to_the_id_image
    assert_equal '/tmp/id/tower.colors.json', SkRubyMcp::Runtime::FacadeCapture.color_table_path('/tmp/id/tower.png')
    assert_equal '/tmp/id/tower.colors.json', SkRubyMcp::Runtime::FacadeCapture.color_table_path('/tmp/id/tower')
    assert_equal '/tmp/a.b/tower.colors.json', SkRubyMcp::Runtime::FacadeCapture.color_table_path('/tmp/a.b/tower.PNG')
  end

  def test_camera_file_reads_inches_snapshot
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'state.json')
      File.write(path, JSON.generate('camera' => { 'eye' => [0, -2000, 200], 'target' => [0, 0, 200], 'up' => [0, 0, 1], 'fov' => 20.0 }))
      cam = Pack::CameraArgument.resolve(nil, path)
      assert_equal [0.0, -2000.0, 200.0], cam[:eye]
      assert_in_delta 20.0, cam[:fov], 1e-9
      assert_equal true, cam[:fov_is_height]
    end
    metres = Pack::CameraArgument.resolve({ 'eye_m' => [1, 2, 3], 'target_m' => [4, 5, 6] }, nil)
    assert_in_delta IN, metres[:eye][0], 1e-6
    assert_equal [0.0, 0.0, 1.0], metres[:up]
    assert_raises(ArgumentError) { Pack::CameraArgument.resolve({ 'eye_m' => [1, 2] }, nil) }
  end
end
