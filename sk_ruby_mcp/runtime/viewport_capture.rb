# frozen_string_literal: true

require 'tmpdir'

module SkRubyMcp
  module Runtime
    CaptureResult = Struct.new(
      :ok, :bytes, :mime, :width, :height, :view, :camera, :error, :message,
      keyword_init: true
    )

    # Снимок вьюпорта: JPEG в память, камера архитектора восстанавливается.
    class ViewportCapture
      MIME = 'image/jpeg'
      DEFAULT_WIDTH = 1280
      DEFAULT_HEIGHT = 720
      MAX_WIDTH = 1600
      MAX_HEIGHT = 1000
      MIN_SIDE = 320
      JPEG_QUALITY = 0.7
      MAX_IMAGE_BYTES = 350_000
      SHRINK_ATTEMPTS = 3
      EMPTY_DISTANCE = 100.0
      VIEW_NAMES = %w[current iso plan front right].freeze
      PRESET_UP = {
        'iso' => [0.0, 0.0, 1.0],
        'plan' => [0.0, 1.0, 0.0],
        'front' => [0.0, 0.0, 1.0],
        'right' => [0.0, 0.0, 1.0]
      }.freeze
      PRESET_DIR = {
        'iso' => [1.0, 1.0, 1.0],
        'plan' => [0.0, 0.0, 1.0],
        'front' => [0.0, -1.0, 0.0],
        'right' => [1.0, 0.0, 0.0]
      }.freeze

      def initialize(model_provider:, temp_dir: nil)
        @model_provider = model_provider
        @temp_dir = temp_dir
      end

      def capture(view_name:, width:, height:)
        model = @model_provider.call
        unless model
          return CaptureResult.new(
            ok: false,
            error: 'no_document',
            message: 'No focused document.'
          )
        end

        view = model.respond_to?(:active_view) ? model.active_view : nil
        unless view && view.respond_to?(:write_image)
          return CaptureResult.new(
            ok: false,
            error: 'capture_failed',
            message: 'The focused document has no viewport to photograph.'
          )
        end
        if view.respond_to?(:vpwidth) && view.vpwidth.to_i < 1
          return CaptureResult.new(
            ok: false,
            error: 'view_not_ready',
            message: 'The SketchUp viewport is not ready (minimized or not yet painted). Show the window and call model_look again.'
          )
        end

        camera = view.respond_to?(:camera) ? view.camera : nil
        if view_name != 'current' && camera && camera.respond_to?(:is_2d?) && camera.is_2d?
          return CaptureResult.new(
            ok: false,
            error: 'two_point_view',
            message: 'This document uses a two-point or match-photo camera. Call model_look with view current.'
          )
        end

        saved = nil
        if view_name != 'current'
          saved = snapshot_camera(camera)
          unless saved
            return CaptureResult.new(
              ok: false,
              error: 'camera_snapshot_failed',
              message: 'Could not read the architect\'s camera, so the named view was not applied. Call model_look with view current.'
            )
          end
        end
        restored = true
        begin
          apply_preset(view, model, view_name) if saved
          bytes, used_w, used_h = write_fitting(view, width, height)
          if bytes.nil?
            outcome = CaptureResult.new(
              ok: false,
              error: 'capture_failed',
              message: 'SketchUp could not write a viewport image.'
            )
          elsif bytes.bytesize > MAX_IMAGE_BYTES
            outcome = CaptureResult.new(
              ok: false,
              error: 'capture_too_large',
              message: 'The viewport image was still too large after shrinking. Call again with a smaller width and height.'
            )
          else
            outcome = CaptureResult.new(
              ok: true,
              bytes: bytes,
              mime: MIME,
              width: used_w,
              height: used_h,
              view: view_name,
              camera: camera_report(view.camera)
            )
          end
        ensure
          restored = restore_camera(view, saved) if saved
        end
        if saved && !restored && outcome.ok
          return CaptureResult.new(
            ok: false,
            error: 'camera_restore_failed',
            message: 'The picture was taken but the architect\'s camera could not be restored.'
          )
        end
        outcome
      end

      private

      def write_fitting(view, width, height)
        used_w = width
        used_h = height
        bytes = nil
        SHRINK_ATTEMPTS.times do
          bytes = write_once(view, used_w, used_h)
          return [nil, used_w, used_h] unless bytes
          return [bytes, used_w, used_h] if bytes.bytesize <= MAX_IMAGE_BYTES

          used_w = [MIN_SIDE, (used_w * 0.75).round].max
          used_h = [MIN_SIDE, (used_h * 0.75).round].max
        end
        [bytes, used_w, used_h]
      end

      def write_once(view, width, height)
        path = File.join(work_dir, "skmcp-look-#{Process.pid}-#{Clock.now}-#{rand(1_000_000)}.jpg")
        options = {
          filename: path,
          width: width,
          height: height,
          antialias: true,
          compression: JPEG_QUALITY
        }
        ok = write_image(view, options, path, width, height)
        return nil unless ok && File.file?(path) && File.size(path).positive?

        File.binread(path)
      ensure
        File.delete(path) if path && File.file?(path)
      end

      def write_image(view, options, path, width, height)
        view.write_image(options)
      rescue ArgumentError, TypeError
        view.write_image(path, width, height, true, JPEG_QUALITY)
      end

      def work_dir
        return @temp_dir if @temp_dir
        return Sketchup.temp_dir if defined?(Sketchup) && Sketchup.respond_to?(:temp_dir)

        Dir.tmpdir
      end

      def apply_preset(view, model, name)
        camera = view.camera
        info = bounds_info(model)
        direction = PRESET_DIR.fetch(name)
        camera.set(offset(info[:center], direction, info[:size]), info[:center], PRESET_UP.fetch(name))
        camera.perspective = name != 'plan'
        zoom_extents(view, model)
      end

      def zoom_extents(view, model)
        return unless view.respond_to?(:zoom)
        return unless model.respond_to?(:entities)

        view.zoom(model.entities)
      rescue *ModelSnapshotFactory::READ_ERRORS
        nil
      end

      def bounds_info(model)
        bounds = model.respond_to?(:bounds) ? model.bounds : nil
        if bounds.nil? || (bounds.respond_to?(:empty?) && bounds.empty?)
          return { center: [0.0, 0.0, 0.0], size: EMPTY_DISTANCE }
        end

        center = xyz(bounds.center)
        return { center: [0.0, 0.0, 0.0], size: EMPTY_DISTANCE } unless center

        size = bounds.respond_to?(:diagonal) ? bounds.diagonal.to_f : EMPTY_DISTANCE
        size = EMPTY_DISTANCE if size <= 0
        { center: center, size: size }
      rescue *ModelSnapshotFactory::READ_ERRORS
        { center: [0.0, 0.0, 0.0], size: EMPTY_DISTANCE }
      end

      def offset(center, direction, size)
        length = size * 1.4
        mag = Math.sqrt(direction[0]**2 + direction[1]**2 + direction[2]**2)
        [
          center[0] + direction[0] / mag * length,
          center[1] + direction[1] / mag * length,
          center[2] + direction[2] / mag * length
        ]
      end

      def snapshot_camera(camera)
        return nil unless camera

        eye = xyz(camera.eye)
        target = xyz(camera.target)
        up = xyz(camera.up)
        return nil unless eye && target && up

        {
          eye: eye,
          target: target,
          up: up,
          perspective: camera.perspective?,
          fov: camera.perspective? ? numeric_or_nil(camera.fov) : nil,
          height: camera.perspective? ? nil : numeric_or_nil(camera.height)
        }
      end

      def restore_camera(view, saved)
        camera = view.camera
        return false unless camera && saved

        camera.set(saved[:eye], saved[:target], saved[:up])
        camera.perspective = saved[:perspective]
        if saved[:perspective]
          camera.fov = saved[:fov] if saved[:fov] && camera.respond_to?(:fov=)
        elsif saved[:height] && camera.respond_to?(:height=)
          camera.height = saved[:height]
        end
        true
      rescue *ModelSnapshotFactory::READ_ERRORS
        false
      end

      def camera_report(camera)
        return nil unless camera

        eye = xyz(camera.eye)
        target = xyz(camera.target)
        up = xyz(camera.up)
        return nil unless eye && target && up

        {
          'eye' => round_xyz(eye),
          'target' => round_xyz(target),
          'up' => round_xyz(up),
          'perspective' => camera.perspective?
        }
      rescue *ModelSnapshotFactory::READ_ERRORS
        nil
      end

      def xyz(point)
        [point.x.to_f, point.y.to_f, point.z.to_f]
      rescue *ModelSnapshotFactory::READ_ERRORS
        nil
      end

      def round_xyz(values)
        values.map { |item| item.to_f.round(2) }
      end

      def numeric_or_nil(value)
        value.respond_to?(:to_f) ? value.to_f : nil
      end
    end
  end
end
