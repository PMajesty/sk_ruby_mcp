# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'schema_check'
require 'base64'

class ModelLookTest < Minitest::Test
  ModelLook = SkRubyMcp::Tools::ModelLook
  SessionResult = SkRubyMcp::Runtime::SessionResult
  ModelSnapshot = SkRubyMcp::Runtime::ModelSnapshot
  CaptureResult = SkRubyMcp::Runtime::CaptureResult

  class LookSession
    attr_reader :calls
    attr_accessor :status_result, :refusal

    def initialize(status_result, refusal: nil)
      @status_result = status_result
      @refusal = refusal
      @calls = []
    end

    def ruby_refusal
      @calls << :refusal
      @refusal
    end

    def status
      @calls << :status
      @status_result
    end

    def empty_document_next
      SkRubyMcp::Runtime::DocumentSession::NEXT_WHEN_EMPTY
    end
  end

  class SpyCapturer
    attr_reader :calls
    attr_accessor :result

    def initialize(result)
      @result = result
      @calls = []
    end

    def capture(view_name:, width:, height:)
      @calls << [view_name, width, height]
      @result
    end
  end

  JPEG = "\xFF\xD8look\xFF\xD9".b

  def active_status
    SessionResult.new(
      ok: true,
      state: 'active',
      snapshot: ModelSnapshot.new(path: '/tmp/house.skp', title: 'house', modified: false, faces: 12)
    )
  end

  def ok_capture(view: 'current', width: 1280, height: 720)
    CaptureResult.new(
      ok: true,
      bytes: JPEG,
      mime: 'image/jpeg',
      width: width,
      height: height,
      view: view,
      camera: { 'eye' => [1.0, 2.0, 3.0], 'target' => [0.0, 0.0, 0.0], 'up' => [0.0, 0.0, 1.0], 'perspective' => true }
    )
  end

  def tool(session: LookSession.new(active_status), capturer: SpyCapturer.new(ok_capture))
    @session = session
    @capturer = capturer
    ModelLook.new(session: session, capturer: capturer)
  end

  def parsed(result)
    JSON.parse(result[:content].first[:text])
  end

  def image_part(result)
    result[:content].find { |item| item[:type] == 'image' }
  end

  def test_spec_is_observational
    spec = tool.spec
    assert_equal 'model_look', spec[:name]
    assert_equal true, spec[:annotations][:readOnlyHint]
    assert_equal false, spec[:annotations][:destructiveHint]
    assert_equal true, spec[:annotations][:idempotentHint]
    assert spec.key?(:outputSchema)
    assert_includes spec[:description], 'Do not poll'
    assert_includes spec[:description], 'model_status'
    assert_equal %w[current iso plan front right], spec[:inputSchema][:properties][:view][:enum]
  end

  def test_success_returns_image_and_json_without_pixels_in_structured
    result = tool.call({})
    refute result[:isError]
    body = parsed(result)
    assert_equal true, body['ok']
    assert_equal 'active', body['state']
    assert_equal 'house', body['title']
    assert_equal 'current', body['view']
    assert_equal 1280, body['width']
    assert_equal 720, body['height']
    assert_equal 'image/jpeg', body['mime']
    assert_equal JPEG.bytesize, body['bytes']
    refute body.key?('data')
    assert_equal result[:structuredContent], body
    image = image_part(result)
    refute_nil image
    assert_equal 'image/jpeg', image[:mimeType]
    assert_equal Base64.strict_encode64(JPEG), image[:data]
    refute_includes JSON.pretty_generate(result[:structuredContent]), image[:data]
    assert SchemaCheck.valid?(SkRubyMcp::Tools::LOOK_OUTPUT_SCHEMA, body)
    assert_equal [['current', 1280, 720]], @capturer.calls
  end

  def test_named_view_and_size_are_passed_through
    tool(capturer: SpyCapturer.new(ok_capture(view: 'iso', width: 800, height: 600)))
      .call('view' => 'iso', 'width' => 800, 'height' => 600)
    assert_equal [['iso', 800, 600]], @capturer.calls
  end

  def test_integer_valued_float_size_is_accepted
    tool.call('width' => 800.0, 'height' => 600.0)
    assert_equal [['current', 800, 600]], @capturer.calls
  end

  def test_unknown_arguments_are_rejected
    result = tool.call('extra' => 1)
    assert result[:isError]
    assert_equal 'unknown_arguments', parsed(result)['error']
    assert_empty @capturer.calls
  end

  def test_invalid_view_is_rejected
    result = tool.call('view' => 'birdseye')
    assert result[:isError]
    assert_equal 'invalid_view', parsed(result)['error']
    assert_empty @capturer.calls
  end

  def test_invalid_size_is_rejected
    too_small = tool.call('width' => 10)
    assert too_small[:isError]
    assert_equal 'invalid_size', parsed(too_small)['error']

    text = tool.call('height' => '720')
    assert text[:isError]
    assert_equal 'invalid_size', parsed(text)['error']

    fractional = tool.call('width' => 800.5)
    assert fractional[:isError]
    assert_equal 'invalid_size', parsed(fractional)['error']
    assert_empty @capturer.calls
  end

  def test_opening_refusal_does_not_capture
    session = LookSession.new(
      SessionResult.new(ok: true, state: 'opening'),
      refusal: {
        class: 'DocumentOpening',
        message: 'A document operation is still opening.',
        next: SkRubyMcp::Runtime::DocumentSession::NEXT_WHEN_OPENING
      }
    )
    result = tool(session: session).call({})
    assert result[:isError]
    assert_equal 'DocumentOpening', parsed(result)['error']
    assert_equal 'model_status', parsed(result)['instead']
    assert_empty @capturer.calls
    refute_includes session.calls, :status
  end

  def test_no_document_status_does_not_capture
    session = LookSession.new(SessionResult.new(ok: true, state: 'no_document', next: 'Call model_new.'))
    result = tool(session: session).call({})
    assert result[:isError]
    assert_equal 'no_document', parsed(result)['error']
    assert_includes parsed(result)['next'], 'model_new'
    refute parsed(result).key?('instead')
    assert_empty @capturer.calls
    assert_nil image_part(result)
  end

  def test_capture_failure_is_a_tool_error
    capturer = SpyCapturer.new(CaptureResult.new(ok: false, error: 'capture_failed', message: 'SketchUp could not write a viewport image.'))
    result = tool(capturer: capturer).call({})
    assert result[:isError]
    assert_equal 'capture_failed', parsed(result)['error']
    assert_equal 'model_look', parsed(result)['instead']
    assert_nil image_part(result)
  end

  def test_capture_too_large_names_a_smaller_call
    capturer = SpyCapturer.new(
      CaptureResult.new(
        ok: false,
        error: 'capture_too_large',
        message: 'The viewport image was still too large after shrinking. Call again with a smaller width and height.'
      )
    )
    result = tool(capturer: capturer).call({})
    assert result[:isError]
    assert_equal 'capture_too_large', parsed(result)['error']
    assert_includes parsed(result)['next'], 'smaller width and height'
    assert_equal 'model_look', parsed(result)['instead']
    assert_nil image_part(result)
  end

  def test_two_point_view_names_current
    capturer = SpyCapturer.new(
      CaptureResult.new(
        ok: false,
        error: 'two_point_view',
        message: 'This document uses a two-point or match-photo camera. Call model_look with view current.'
      )
    )
    result = tool(capturer: capturer).call('view' => 'iso')
    assert result[:isError]
    assert_equal 'two_point_view', parsed(result)['error']
    assert_equal 'Call model_look with view current.', parsed(result)['next']
    assert_equal 'model_look', parsed(result)['instead']
  end

  def test_view_not_ready_asks_to_show_the_window
    capturer = SpyCapturer.new(
      CaptureResult.new(
        ok: false,
        error: 'view_not_ready',
        message: 'The SketchUp viewport is not ready (minimized or not yet painted). Show the window and call model_look again.'
      )
    )
    result = tool(capturer: capturer).call({})
    assert result[:isError]
    assert_equal 'view_not_ready', parsed(result)['error']
    assert_equal 'Show the SketchUp window and call model_look again.', parsed(result)['next']
  end

  def test_camera_snapshot_failed_names_current
    capturer = SpyCapturer.new(
      CaptureResult.new(
        ok: false,
        error: 'camera_snapshot_failed',
        message: 'Could not read the architect\'s camera, so the named view was not applied. Call model_look with view current.'
      )
    )
    result = tool(capturer: capturer).call('view' => 'iso')
    assert result[:isError]
    assert_equal 'camera_snapshot_failed', parsed(result)['error']
    assert_equal 'Call model_look with view current.', parsed(result)['next']
  end

  def test_camera_restore_failed_names_a_retry
    capturer = SpyCapturer.new(
      CaptureResult.new(
        ok: false,
        error: 'camera_restore_failed',
        message: 'The picture was taken but the architect\'s camera could not be restored.'
      )
    )
    result = tool(capturer: capturer).call('view' => 'iso')
    assert result[:isError]
    assert_equal 'camera_restore_failed', parsed(result)['error']
    assert_equal 'Call model_look again, or use model_status if the document is gone.', parsed(result)['next']
  end

  def test_untitled_path_stays_null
    session = LookSession.new(
      SessionResult.new(
        ok: true,
        state: 'active',
        snapshot: ModelSnapshot.new(path: nil, title: '', modified: false)
      )
    )
    body = parsed(tool(session: session).call({}))
    assert body.key?('path')
    assert_nil body['path']
    assert_equal 'Untitled', body['title']
  end
end
