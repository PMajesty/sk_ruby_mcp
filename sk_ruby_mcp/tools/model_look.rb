# frozen_string_literal: true

require 'base64'

module SkRubyMcp
  module Tools
    # Снимок вьюпорта как MCP image, чтобы модель могла увидеть документ.
    class ModelLook
      NAME = 'model_look'
      TITLE = 'Look at the SketchUp viewport'
      DEFAULT_WIDTH = Runtime::ViewportCapture::DEFAULT_WIDTH
      DEFAULT_HEIGHT = Runtime::ViewportCapture::DEFAULT_HEIGHT
      VIEW_NAMES = Runtime::ViewportCapture::VIEW_NAMES

      INPUT_SCHEMA = {
        type: 'object',
        properties: {
          view: {
            type: 'string',
            enum: VIEW_NAMES.dup,
            description: 'Camera for the shot (default current). current is the architect\'s view; iso, plan, front and right frame the whole model and then restore the camera.'
          },
          width: {
            type: 'integer',
            minimum: Runtime::ViewportCapture::MIN_SIDE,
            maximum: Runtime::ViewportCapture::MAX_WIDTH,
            description: "Image width in pixels (default #{DEFAULT_WIDTH}, max #{Runtime::ViewportCapture::MAX_WIDTH})."
          },
          height: {
            type: 'integer',
            minimum: Runtime::ViewportCapture::MIN_SIDE,
            maximum: Runtime::ViewportCapture::MAX_HEIGHT,
            description: "Image height in pixels (default #{DEFAULT_HEIGHT}, max #{Runtime::ViewportCapture::MAX_HEIGHT})."
          }
        },
        additionalProperties: false
      }.freeze

      ALLOWED_ARGUMENT_KEYS = INPUT_SCHEMA[:properties].keys.map(&:to_s).freeze

      ANNOTATIONS = {
        title: TITLE,
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      }.freeze

      DESCRIPTION = <<~TEXT.strip
        Photograph the focused SketchUp viewport and return a JPEG the client can show you. Use this when you need to see the model: alignment, missing floors, a wrong extrusion, empty space. Do not poll this; model_status is the cheap picture. The architect's camera is restored after iso, plan, front or right. Nothing is saved or discarded. Call only when a document is focused (state active).
        Arguments: view (optional: current, iso, plan, front, right; default current). current is whatever the architect is looking at. iso is a northeast view of the whole model. plan is top-down parallel. front looks north. right looks west. width and height (optional integers, default 1280×720, max 1600×1000). Smaller is faster. The reply is an image plus JSON with view, size and the camera used for the shot.
      TEXT

      def initialize(session:, capturer:)
        raise ArgumentError, 'session is required' if session.nil?
        raise ArgumentError, 'capturer is required' if capturer.nil?

        @session = session
        @capturer = capturer
      end

      def name
        NAME
      end

      def polls_while_busy?
        false
      end

      def spec
        {
          name: NAME,
          title: TITLE,
          description: DESCRIPTION,
          inputSchema: INPUT_SCHEMA,
          outputSchema: LOOK_OUTPUT_SCHEMA,
          annotations: ANNOTATIONS
        }
      end

      def call(arguments)
        arguments = {} unless arguments.is_a?(Hash)
        unknown = ArgumentGuard.unknown_message(arguments, ALLOWED_ARGUMENT_KEYS)
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

        view_name = view_from(arguments)
        return view_name if view_name.is_a?(Hash)

        width = dimension_from(arguments, 'width', DEFAULT_WIDTH, Runtime::ViewportCapture::MAX_WIDTH)
        return width if width.is_a?(Hash)

        height = dimension_from(arguments, 'height', DEFAULT_HEIGHT, Runtime::ViewportCapture::MAX_HEIGHT)
        return height if height.is_a?(Hash)

        status = @session.status
        unless status.ok && status.state == 'active'
          return look_unavailable(status)
        end

        result = @capturer.capture(view_name: view_name, width: width, height: height)
        unless result.ok
          return ToolReply.call(
            ok: false,
            error: result.error,
            message: result.message,
            retry: result.error != 'no_document',
            instead: result.error == 'no_document' ? nil : 'model_look',
            next: next_for(result)
          )
        end

        snap = status.snapshot
        payload = {
          ok: true,
          state: 'active',
          path: snap && Runtime::PathIdentity.display(snap.path),
          title: snap && (snap.title.to_s.empty? ? 'Untitled' : snap.title),
          view: result.view,
          width: result.width,
          height: result.height,
          mime: result.mime,
          bytes: result.bytes.bytesize,
          camera: result.camera
        }
        ToolReply.call(
          payload,
          [{
            type: 'image',
            data: Base64.strict_encode64(result.bytes),
            mimeType: result.mime
          }]
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

      def view_from(arguments)
        raw = arguments.key?('view') ? arguments['view'] : 'current'
        return raw if VIEW_NAMES.include?(raw)

        ToolReply.call(
          ok: false,
          error: 'invalid_view',
          message: 'view must be current, iso, plan, front or right.',
          retry: false,
          next: 'Pass view as current, iso, plan, front or right, or omit it.'
        )
      end

      def dimension_from(arguments, key, default, max)
        raw = arguments[key]
        return default if raw.nil?

        if raw.is_a?(Integer)
          value = raw
        elsif raw.is_a?(Numeric) && raw == raw.to_i
          value = raw.to_i
        else
          return invalid_dimension(key)
        end
        return invalid_dimension(key) if value < Runtime::ViewportCapture::MIN_SIDE || value > max

        value
      end

      def invalid_dimension(key)
        ToolReply.call(
          ok: false,
          error: 'invalid_size',
          message: "#{key} must be an integer from #{Runtime::ViewportCapture::MIN_SIDE} to the documented maximum.",
          retry: false,
          next: "Pass #{key} as an integer, or omit it."
        )
      end

      def look_unavailable(status)
        ToolReply.call(
          ok: false,
          state: status.state,
          error: status.code || status.state,
          message: status.message || (status.state == 'opening' ? 'A document is still opening.' : 'No focused document.'),
          retry: status.state == 'opening',
          instead: status.state == 'opening' ? 'model_status' : nil,
          next: status.next || (status.state == 'opening' ? Runtime::DocumentSession::NEXT_WHEN_OPENING : Runtime::DocumentSession::NEXT_WHEN_EMPTY)
        )
      end

      def next_for(result)
        case result.error
        when 'no_document'
          @session.empty_document_next
        when 'capture_too_large'
          'Call model_look with a smaller width and height.'
        when 'two_point_view'
          'Call model_look with view current.'
        when 'view_not_ready'
          'Show the SketchUp window and call model_look again.'
        when 'camera_snapshot_failed'
          'Call model_look with view current.'
        else
          'Call model_look again, or use model_status if the document is gone.'
        end
      end
    end
  end
end
