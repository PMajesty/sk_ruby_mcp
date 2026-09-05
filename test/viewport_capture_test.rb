# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'

class ViewportCaptureTest < Minitest::Test
  ViewportCapture = SkRubyMcp::Runtime::ViewportCapture
  CaptureResult = SkRubyMcp::Runtime::CaptureResult

  class FakePoint
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x
      @y = y
      @z = z
    end
  end

  class FakeCamera
    attr_accessor :eye, :target, :up, :fov, :height
    attr_reader :perspective

    def initialize(eye:, target:, up:, perspective: true, fov: 35.0, height: 100.0)
      @eye = point(eye)
      @target = point(target)
      @up = point(up)
      @perspective = perspective
      @fov = fov
      @height = height
    end

    def perspective?
      @perspective
    end

    def perspective=(value)
      @perspective = value
    end

    def set(eye, target, up)
      @eye = point(eye)
      @target = point(target)
      @up = point(up)
    end

    def point(value)
      return value if value.respond_to?(:x)

      FakePoint.new(value[0], value[1], value[2])
    end
  end

  class FakeBounds
    def initialize(center:, diagonal:, empty: false)
      @center = center
      @diagonal = diagonal
      @empty = empty
    end

    def empty?
      @empty
    end

    def center
      @center
    end

    def diagonal
      @diagonal
    end
  end

  class FakeView
    attr_reader :camera, :writes, :zooms
    attr_accessor :payload, :fail_write, :reject_hash

    def initialize(camera:, payload: "\xFF\xD8tiny\xFF\xD9")
      @camera = camera
      @payload = payload
      @writes = []
      @zooms = []
      @fail_write = false
      @reject_hash = false
    end

    def write_image(*args)
      raise ArgumentError, 'no keywords' if @reject_hash && args.first.is_a?(Hash)
      return false if @fail_write

      options = args.first.is_a?(Hash) ? args.first : { filename: args[0], width: args[1], height: args[2] }
      @writes << options
      File.binwrite(options[:filename] || options['filename'], @payload)
      true
    end

    def zoom(entities)
      @zooms << entities
    end
  end

  class FakeModel
    attr_reader :active_view, :bounds, :entities

    def initialize(view:, bounds: FakeBounds.new(center: FakePoint.new(10.0, 20.0, 30.0), diagonal: 50.0), entities: [:ents])
      @active_view = view
      @bounds = bounds
      @entities = entities
    end
  end

  def capture_for(model, temp_dir: nil)
    ViewportCapture.new(model_provider: -> { model }, temp_dir: temp_dir || Dir.mktmpdir('skmcp-look'))
  end

  def coords(point)
    [point.x.to_f, point.y.to_f, point.z.to_f]
  end

  def failing_restore_camera
    camera = FakeCamera.new(eye: [1, 2, 3], target: [4, 5, 6], up: [0, 0, 1], fov: 40.0)
    sets = 0
    camera.define_singleton_method(:set) do |eye, target, up|
      sets += 1
      raise TypeError, 'restore failed' if sets > 1

      @eye = point(eye)
      @target = point(target)
      @up = point(up)
    end
    camera
  end

  def test_current_view_writes_jpeg_and_leaves_camera_alone
    camera = FakeCamera.new(eye: [1, 2, 3], target: [0, 0, 0], up: [0, 0, 1])
    view = FakeView.new(camera: camera)
    model = FakeModel.new(view: view)
    result = capture_for(model).capture(view_name: 'current', width: 640, height: 480)

    assert result.ok
    assert_equal "\xFF\xD8tiny\xFF\xD9".b, result.bytes
    assert_equal 'image/jpeg', result.mime
    assert_equal 640, result.width
    assert_equal 480, result.height
    assert_equal 'current', result.view
    assert_equal [1.0, 2.0, 3.0], coords(camera.eye)
    assert_empty view.zooms
    assert_equal 1, view.writes.size
    refute File.exist?(view.writes.first[:filename])
  end

  def test_iso_moves_then_restores_the_camera
    camera = FakeCamera.new(eye: [1, 2, 3], target: [4, 5, 6], up: [0, 0, 1], fov: 40.0)
    view = FakeView.new(camera: camera)
    model = FakeModel.new(view: view)
    result = capture_for(model).capture(view_name: 'iso', width: 640, height: 480)

    assert result.ok
    assert_equal [1.0, 2.0, 3.0], coords(camera.eye)
    assert_equal [4.0, 5.0, 6.0], coords(camera.target)
    assert_equal [0.0, 0.0, 1.0], coords(camera.up)
    assert_equal true, camera.perspective?
    assert_equal 40.0, camera.fov
    assert_equal [[:ents]], view.zooms
    assert_equal 'iso', result.view
  end

  def test_plan_uses_parallel_projection_then_restores
    camera = FakeCamera.new(eye: [0, 0, 10], target: [0, 0, 0], up: [0, 0, 1], perspective: true, fov: 35.0)
    view = FakeView.new(camera: camera)
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'plan', width: 640, height: 480)

    assert result.ok
    assert_equal true, camera.perspective?
    assert_equal 35.0, camera.fov
  end

  def test_no_model_is_a_failed_capture
    result = ViewportCapture.new(model_provider: -> { nil }).capture(view_name: 'current', width: 640, height: 480)
    refute result.ok
    assert_equal 'no_document', result.error
  end

  def test_write_failure_is_reported
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    view = FakeView.new(camera: camera)
    view.fail_write = true
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'current', width: 640, height: 480)
    refute result.ok
    assert_equal 'capture_failed', result.error
  end

  def test_hash_write_falling_back_to_positional
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    view = FakeView.new(camera: camera)
    view.reject_hash = true
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'current', width: 640, height: 480)
    assert result.ok
    assert_equal 640, view.writes.last[:width]
  end

  def test_oversized_image_is_retried_smaller
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    view = FakeView.new(camera: camera, payload: 'x' * (ViewportCapture::MAX_IMAGE_BYTES + 10))
    sizes = [
      'x' * (ViewportCapture::MAX_IMAGE_BYTES + 10),
      'ok'
    ]
    view.define_singleton_method(:write_image) do |*args|
      options = args.first.is_a?(Hash) ? args.first : { filename: args[0], width: args[1], height: args[2] }
      @writes << options
      File.binwrite(options[:filename] || options['filename'], sizes.shift)
      true
    end
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'current', width: 1600, height: 1000)
    assert result.ok
    assert_equal 'ok', result.bytes
    assert result.width < 1600
    assert result.height < 1000
    assert_equal 2, view.writes.size
  end

  def unreadable_point
    Object.new
  end

  def test_empty_bounds_still_captures
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    view = FakeView.new(camera: camera)
    bounds = FakeBounds.new(center: FakePoint.new(0, 0, 0), diagonal: 0, empty: true)
    result = capture_for(FakeModel.new(view: view, bounds: bounds)).capture(view_name: 'front', width: 640, height: 480)
    assert result.ok
    assert_equal [0.0, 0.0, 1.0], coords(camera.eye)
  end

  def test_image_still_too_large_after_all_shrinks
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    view = FakeView.new(camera: camera, payload: 'x' * (ViewportCapture::MAX_IMAGE_BYTES + 20))
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'current', width: 1600, height: 1000)
    refute result.ok
    assert_equal 'capture_too_large', result.error
    assert_equal ViewportCapture::SHRINK_ATTEMPTS, view.writes.size
  end

  def test_restore_failure_is_not_success
    view = FakeView.new(camera: failing_restore_camera)
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'iso', width: 640, height: 480)
    refute result.ok
    assert_equal 'camera_restore_failed', result.error
    assert_includes result.message, 'picture was taken'
  end

  def test_named_view_write_failure_is_not_reported_as_restore
    view = FakeView.new(camera: failing_restore_camera)
    view.fail_write = true
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'iso', width: 640, height: 480)
    refute result.ok
    assert_equal 'capture_failed', result.error
    refute_includes result.message, 'picture was taken'
  end

  def test_named_view_too_large_is_not_reported_as_restore
    view = FakeView.new(camera: failing_restore_camera, payload: 'x' * (ViewportCapture::MAX_IMAGE_BYTES + 20))
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'iso', width: 1600, height: 1000)
    refute result.ok
    assert_equal 'capture_too_large', result.error
    refute_includes result.message, 'picture was taken'
  end

  def test_named_view_fails_closed_when_camera_is_unreadable
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    bad = unreadable_point
    camera.eye = bad
    view = FakeView.new(camera: camera)
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'iso', width: 640, height: 480)
    refute result.ok
    assert_equal 'camera_snapshot_failed', result.error
    assert_empty view.writes
    assert_same bad, camera.eye
  end

  def test_current_view_omits_camera_when_eye_is_unreadable
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    camera.eye = unreadable_point
    view = FakeView.new(camera: camera)
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'current', width: 640, height: 480)
    assert result.ok
    assert_nil result.camera
    assert_equal 1, view.writes.size
  end

  def test_unreadable_bounds_center_still_captures_named_view
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    view = FakeView.new(camera: camera)
    bounds = FakeBounds.new(center: unreadable_point, diagonal: 50.0, empty: false)
    result = capture_for(FakeModel.new(view: view, bounds: bounds)).capture(view_name: 'front', width: 640, height: 480)
    assert result.ok
    assert_equal [0.0, 0.0, 1.0], coords(camera.eye)
    assert_equal 1, view.writes.size
  end

  def test_zero_vpwidth_is_view_not_ready
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    view = FakeView.new(camera: camera)
    view.define_singleton_method(:vpwidth) { 0 }
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'current', width: 640, height: 480)
    refute result.ok
    assert_equal 'view_not_ready', result.error
    assert_empty view.writes
  end

  def test_two_point_camera_refuses_named_views
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    camera.define_singleton_method(:is_2d?) { true }
    view = FakeView.new(camera: camera)
    result = capture_for(FakeModel.new(view: view)).capture(view_name: 'iso', width: 640, height: 480)
    refute result.ok
    assert_equal 'two_point_view', result.error
    assert_empty view.writes
  end

  def test_temp_file_is_gone_after_a_failed_write
    dir = Dir.mktmpdir('skmcp-look')
    camera = FakeCamera.new(eye: [0, 0, 1], target: [0, 0, 0], up: [0, 0, 1])
    view = FakeView.new(camera: camera)
    view.fail_write = true
    capture_for(FakeModel.new(view: view), temp_dir: dir).capture(view_name: 'current', width: 640, height: 480)
    assert_empty Dir.children(dir)
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end
end
