# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'schema_check'
require 'tmpdir'
require 'fileutils'

class ArchitectPackTest < Minitest::Test
  Pack = SkRubyMcp::Tools::ArchitectPack
  SessionResult = SkRubyMcp::Runtime::SessionResult
  ModelSnapshot = SkRubyMcp::Runtime::ModelSnapshot

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

    def width
      @max.x - @min.x
    end

    def height
      @max.y - @min.y
    end

    def depth
      @max.z - @min.z
    end

    def corner(index)
      x = (index & 1).zero? ? @min.x : @max.x
      y = (index & 2).zero? ? @min.y : @max.y
      z = (index & 4).zero? ? @min.z : @max.z
      FakePoint.new(x, y, z)
    end
  end

  class FakeLayer
    attr_reader :name

    def initialize(name)
      @name = name
    end
  end

  class FakeLayers
    def initialize
      @by_name = { 'Layer0' => FakeLayer.new('Layer0') }
    end

    def [](name)
      @by_name[name]
    end

    def add(name)
      @by_name[name] = FakeLayer.new(name)
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
  end

  class FakeFace
    attr_reader :normal, :parent, :vertices

    def initialize(pts, parent)
      @parent = parent
      @vertices = pts
      @normal = FakePoint.new(0, 0, 1)
    end

    def reverse!
      @normal = FakePoint.new(@normal.x, @normal.y, -@normal.z)
      self
    end

    def pushpull(distance)
      owner = @parent.owner
      return unless owner.respond_to?(:size_z=)

      owner.size_z = distance.abs
    end
  end

  class FakeEntities
    attr_reader :items
    attr_accessor :owner

    def initialize(owner = nil)
      @owner = owner
      @items = []
    end

    def add_group
      group = FakeGroup.new
      group.parent_entities = self
      @items << group
      group
    end

    def add_face(*pts)
      pts = pts.first if pts.size == 1 && pts.first.is_a?(Array) && pts.first.first.is_a?(Array)
      xs = pts.map { |pt| pt.is_a?(Array) ? pt[0] : pt.x }
      ys = pts.map { |pt| pt.is_a?(Array) ? pt[1] : pt.y }
      zs = pts.map { |pt| pt.is_a?(Array) ? pt[2] : pt.z }
      if @owner.respond_to?(:origin=)
        @owner.origin = [xs.min, ys.min, zs.min]
        @owner.size_xy = [xs.max - xs.min, ys.max - ys.min]
      end
      face = FakeFace.new(pts, self)
      @items << face
      face
    end

    def each(&block)
      @items.each(&block)
    end
  end

  class FakeGroup
    attr_accessor :name, :layer, :material, :parent_entities, :origin, :size_xy, :size_z
    attr_reader :entities, :transformation

    def initialize
      @name = ''
      @entities = FakeEntities.new(self)
      @transformation = :identity
      @layer = FakeLayer.new('Layer0')
      @origin = [0.0, 0.0, 0.0]
      @size_xy = [0.0, 0.0]
      @size_z = 0.0
    end

    def bounds
      ox, oy, oz = @origin
      sx, sy = @size_xy
      FakeBounds.new(
        FakePoint.new(ox, oy, oz),
        FakePoint.new(ox + sx, oy + sy, oz + @size_z)
      )
    end
  end

  class FakeView
    attr_reader :invalidations

    def initialize
      @invalidations = 0
    end

    def invalidate
      @invalidations += 1
    end
  end

  class FakeModel
    attr_reader :entities, :layers, :materials, :events, :active_view
    attr_accessor :path, :title

    def initialize
      @entities = FakeEntities.new
      @layers = FakeLayers.new
      @materials = FakeMaterials.new
      @events = []
      @active_view = FakeView.new
      @path = ''
      @title = 'Untitled'
    end

    def active_entities
      @entities
    end

    def valid?
      true
    end

    def bounds
      FakeBounds.new(FakePoint.new(0, 0, 0), FakePoint.new(0, 0, 0))
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
    attr_accessor :status_result, :refusal

    def initialize(status_result, refusal: nil)
      @status_result = status_result
      @refusal = refusal
    end

    def ruby_refusal
      @refusal
    end

    def status
      @status_result
    end

    def empty_document_next
      SkRubyMcp::Runtime::DocumentSession::NEXT_WHEN_EMPTY
    end
  end

  def active_status
    SessionResult.new(
      ok: true,
      state: 'active',
      snapshot: ModelSnapshot.new(path: nil, title: 'Untitled', modified: true, faces: 0)
    )
  end

  def parsed(result)
    JSON.parse(result[:content].first[:text])
  end

  def setup
    @model = FakeModel.new
    @session = FakeSession.new(active_status)
    @attach = FakeAttach.new(@model)
  end

  def place_box
    Pack::PlaceBox.new(session: @session, attach: @attach)
  end

  def test_flag_defaults_off_and_follows_the_file
    previous = Pack.flag_path
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'architect_pack.on')
      Pack.flag_path = path
      refute Pack.enabled?
      File.write(path, "on\n")
      assert Pack.enabled?
    end
  ensure
    Pack.flag_path = previous
  end

  def test_place_box_spec_is_destructive_and_metres
    spec = place_box.spec
    assert_equal 'place_box', spec[:name]
    assert_equal ['size_m'], spec[:inputSchema][:required]
    assert_equal true, spec[:annotations][:destructiveHint]
    assert_includes spec[:description], 'metres'
    assert SchemaCheck.valid?(spec[:outputSchema], 'ok' => true, 'name' => 'A')
  end

  def test_unknown_arguments_are_rejected
    result = place_box.call('size_m' => [10, 10, 3], 'bogus' => 1)
    assert result[:isError]
    assert_equal 'unknown_arguments', parsed(result)['error']
    assert_empty @model.entities.items
  end

  def test_place_box_creates_a_named_group_and_commits_undo
    result = place_box.call(
      'size_m' => [12.0, 8.0, 19.8],
      'origin_m' => [1.0, 2.0, 0.0],
      'name' => 'Секция',
      'storeys' => 6,
      'tag' => 'Жильё',
      'color' => '#CC6644'
    )
    refute result[:isError], parsed(result).inspect
    body = parsed(result)
    assert_equal true, body['ok']
    assert_equal 'Секция', body['name']
    assert_equal 6, body['storeys']
    assert_equal 6, body['storey_names'].length
    group = @model.entities.items.first
    assert_equal 'Секция', group.name
    assert_equal 'Жильё', group.layer.name
    assert_equal [204, 102, 68], group.material
    assert_includes @model.events, [:start, 'MCP place_box', true]
    assert_includes @model.events, [:commit]
    listed = Pack::ListGroups.new(session: @session, attach: @attach).call({})
    names = parsed(listed)['groups'].map { |row| row['name'] }
    assert_includes names, 'Секция'
    assert_includes names, 'Этаж 01'
  end

  def test_site_metrics_coverage_from_top_level_boxes
    place_box.call('size_m' => [40.0, 20.0, 19.8], 'name' => 'A')
    result = Pack::SiteMetrics.new(session: @session, attach: @attach).call(
      'site_w_m' => 80,
      'site_d_m' => 60,
      'storey_h_m' => 3.3
    )
    refute result[:isError], parsed(result).inspect
    body = parsed(result)
    assert_in_delta 800.0, body['groups_footprint_m2'], 1.0
    assert_in_delta 80.0 * 60.0, body['site_area_m2'], 0.01
    assert_in_delta 800.0 / 4800.0, body['coverage_groups'], 0.01
    assert body['gfa_m2'] > 800.0
  end

  def test_site_metrics_skips_short_site_plates
    place_box.call('size_m' => [40.0, 20.0, 19.8], 'name' => 'A')
    place_box.call('size_m' => [80.0, 60.0, 0.1], 'name' => 'Site')
    result = Pack::SiteMetrics.new(session: @session, attach: @attach).call(
      'site_w_m' => 80,
      'site_d_m' => 60
    )
    body = parsed(result)
    names = body['groups'].map { |row| row['name'] }
    refute_includes names, 'Site'
    assert_in_delta 800.0, body['groups_footprint_m2'], 1.0
  end

  def test_grid_openings_missing_group
    result = Pack::GridOpenings.new(session: @session, attach: @attach).call(
      'group_name' => 'Missing',
      'facing' => 'south',
      'cols' => 2,
      'rows' => 2,
      'width_m' => 1.5,
      'height_m' => 1.6
    )
    assert result[:isError]
    assert_equal 'group_not_found', parsed(result)['error']
  end

  def test_instances_lists_four_tools
    names = Pack.instances(session: @session, attach: @attach).map(&:name)
    assert_equal %w[place_box list_groups site_metrics grid_openings], names
  end

  def test_list_groups_is_read_only
    spec = Pack::ListGroups.new(session: @session, attach: @attach).spec
    assert_equal true, spec[:annotations][:readOnlyHint]
  end
end
