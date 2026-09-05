# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'

class SkpHeaderTest < Minitest::Test
  SkpHeader = SkRubyMcp::Runtime::SkpHeader
  PathIdentity = SkRubyMcp::Runtime::PathIdentity
  Factory = SkRubyMcp::Runtime::ModelSnapshotFactory

  def test_valid_header_reports_major
    dir = Dir.mktmpdir
    path = File.join(dir, 'a.skp')
    TestSupport.write_skp(path, major: 24, minor: 0, build: 1)
    parsed = SkpHeader.parse(path)
    assert parsed[:ok]
    assert_equal 24, parsed[:written_by_major]
  ensure
    FileUtils.remove_entry(dir)
  end

  def test_plain_text_is_not_a_skp
    dir = Dir.mktmpdir
    path = File.join(dir, 'a.skp')
    File.write(path, 'skp')
    parsed = SkpHeader.parse(path)
    refute parsed[:ok]
    assert_equal 'not_a_skp_file', parsed[:error]
  ensure
    FileUtils.remove_entry(dir)
  end

  def test_display_canonicalises_parent_when_file_is_missing
    displayed = PathIdentity.display('/tmp/missing-sk-mcp.skp')
    parent = File.realpath('/tmp')
    assert_equal File.join(parent, 'missing-sk-mcp.skp'), displayed
  end

  def test_snapshot_uses_number_faces_and_lists_only_top_level_objects
    nested = Object.new
    def nested.class
      Class.new { def self.name; 'Sketchup::Face'; end }.tap { |k| k.define_singleton_method(:name) { 'Sketchup::Face' } }
    end

    group = Object.new
    def group.class
      Class.new.tap { |k| k.define_singleton_method(:name) { 'Sketchup::Group' } }
    end
    def group.name
      'tower'
    end
    def group.entities
      [:nested_face]
    end
    def group.bounds
      nil
    end

    model = Object.new
    def model.valid?
      true
    end
    def model.path
      ''
    end
    def model.title
      'blank'
    end
    def model.modified?
      false
    end
    def model.number_faces
      12
    end
    def model.entities
      @entities
    end
    model.instance_variable_set(:@entities, [group, :edge])
    def model.selection
      []
    end
    def model.layers
      []
    end
    def model.materials
      []
    end

    snap = Factory.from_model(model)
    assert_equal 12, snap.faces
    assert_equal 2, snap.root_entities
    assert_equal 1, snap.objects.size
    assert_equal 'Group', snap.objects.first[:kind]
    assert_equal 'tower', snap.objects.first[:name]
    refute snap.objects_truncated
  end

  def test_object_at_is_the_world_bounds_corner
    metres = lambda do |value|
      length = Object.new
      length.define_singleton_method(:to_m) { value }
      length
    end
    point = lambda do |x, y, z|
      origin = Object.new
      origin.define_singleton_method(:x) { metres.call(x) }
      origin.define_singleton_method(:y) { metres.call(y) }
      origin.define_singleton_method(:z) { metres.call(z) }
      origin
    end
    box = Object.new
    box.define_singleton_method(:min) { point.call(5.4, 11.2, 0.45) }
    box.define_singleton_method(:max) { point.call(7.4, 13.2, 3.45) }
    box.define_singleton_method(:width) { metres.call(2.0) }
    box.define_singleton_method(:height) { metres.call(2.0) }
    box.define_singleton_method(:depth) { metres.call(3.0) }
    transform = Object.new
    transform.define_singleton_method(:origin) { point.call(0.0, 0.0, 0.0) }

    group = Object.new
    group.define_singleton_method(:class) do
      Class.new.tap { |k| k.define_singleton_method(:name) { 'Sketchup::Group' } }
    end
    group.define_singleton_method(:name) { 'studio' }
    group.define_singleton_method(:entities) { [] }
    group.define_singleton_method(:bounds) { box }
    group.define_singleton_method(:transformation) { transform }

    model = Object.new
    model.define_singleton_method(:valid?) { true }
    model.define_singleton_method(:path) { '' }
    model.define_singleton_method(:title) { 'blank' }
    model.define_singleton_method(:modified?) { false }
    model.define_singleton_method(:number_faces) { 1 }
    model.define_singleton_method(:entities) { [group] }
    model.define_singleton_method(:selection) { [] }
    model.define_singleton_method(:layers) { [] }
    model.define_singleton_method(:materials) { [] }

    snap = Factory.from_model(model)
    assert_equal [5.4, 11.2, 0.45], snap.objects.first[:at]
    assert_equal [2.0, 2.0, 3.0], snap.objects.first[:bounds_m]
  end

  def test_snapshot_omits_inverted_empty_bounds
    model = Object.new
    def model.valid?
      true
    end
    def model.path
      ''
    end
    def model.title
      ''
    end
    def model.modified?
      false
    end
    def model.number_faces
      0
    end
    def model.entities
      []
    end
    def model.selection
      []
    end
    def model.layers
      []
    end
    def model.materials
      []
    end
    def model.bounds
      box = Object.new
      def box.empty?
        false
      end
      def box.min
        point = Object.new
        def point.x
          1.0e28
        end
        def point.y
          1.0e28
        end
        def point.z
          1.0e28
        end
        point
      end
      def box.max
        point = Object.new
        def point.x
          -1.0e28
        end
        def point.y
          -1.0e28
        end
        def point.z
          -1.0e28
        end
        point
      end
      box
    end

    snap = Factory.from_model(model)
    assert_nil snap.bounds_m
    assert_equal 0, snap.faces
    assert_equal 0, snap.root_entities
  end
end
