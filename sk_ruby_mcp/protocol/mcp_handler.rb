# frozen_string_literal: true

module SkRubyMcp
  module Protocol
    # Методы MCP поверх JSON-RPC: initialize, ping, tools, resources/howto.
    class McpHandler
      attr_writer :on_cancel
      LATEST_PROTOCOL_VERSION = '2025-11-25'
      SUPPORTED_PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
      GATE_BUSY = Tools::ToolReply::GATE_BUSY

      def initialize(tools:, server_info:, instructions:, call_gate: nil, on_cancel: nil)
        @tools = tools.each_with_object({}) { |tool, by_name| by_name[tool.name] = tool }.freeze
        @server_info = server_info
        @instructions = instructions
        @call_gate = call_gate
        @on_cancel = on_cancel
        @tools_list_result = { tools: tools.map(&:spec) }.freeze
      end

      # Hash ответа или nil, если ответ не нужен (уведомление либо ответ клиента).
      def handle(body)
        message = JsonRpc.parse(body)
        if message.method == 'notifications/cancelled'
          cancel(message.params)
          return nil unless message.request?
        end
        return nil unless message.request?

        dispatched = dispatch(message)
        if dispatched.is_a?(Runtime::Deferred)
          dispatched.rpc_id = message.id
          return dispatched
        end
        JsonRpc.success(message.id, dispatched)
      rescue JsonRpc::ProtocolError => error
        JsonRpc.error(error.id, error.code, error.message)
      rescue StandardError, ScriptError => error
        JsonRpc.error(message&.id, JsonRpc::INTERNAL_ERROR, "Internal error: #{error.class}: #{error.message}")
      end

      private

      def dispatch(message)
        params = message.params || {}
        case message.method
        when 'initialize' then initialize_result(params)
        when 'ping' then {}
        when 'tools/list' then @tools_list_result
        when 'tools/call' then call_tool(params, message.id)
        when 'notifications/cancelled'
          cancel(params)
          {}
        when 'resources/list' then { resources: [howto_listing] }
        when 'resources/read' then read_resource(params, message.id)
        when 'resources/templates/list' then { resourceTemplates: [] }
        when 'prompts/list' then { prompts: [] }
        else
          raise JsonRpc::ProtocolError.new(JsonRpc::METHOD_NOT_FOUND, "Method not found: #{message.method}", id: message.id)
        end
      end

      def initialize_result(params)
        requested = params['protocolVersion']
        version = SUPPORTED_PROTOCOL_VERSIONS.include?(requested) ? requested : LATEST_PROTOCOL_VERSION
        {
          protocolVersion: version,
          capabilities: { tools: {}, resources: {} },
          serverInfo: @server_info,
          instructions: @instructions
        }
      end

      def polls_while_busy?(tool)
        tool.respond_to?(:polls_while_busy?) && tool.polls_while_busy?
      end

      def call_tool(params, id)
        name = params['name'].to_s
        tool = @tools[name]
        raise JsonRpc::ProtocolError.new(JsonRpc::INVALID_PARAMS, "Unknown tool: #{params['name']}", id: id) unless tool

        if !polls_while_busy?(tool) && @call_gate && !@call_gate.try_mutating
          return Tools::ToolReply.call(GATE_BUSY)
        end

        @in_flight_id = id
        arguments = params['arguments']
        result = tool.call(arguments.is_a?(Hash) ? arguments : {})
        if result.is_a?(Runtime::Deferred) && @call_gate && !polls_while_busy?(tool)
          result.attach_gate(@call_gate)
        end
        result
      rescue JsonRpc::ProtocolError
        raise
      rescue StandardError, ScriptError
        Tools::ToolReply.call(
          ok: false,
          error: 'ruby_error',
          message: 'A tool failed. Call model_status and continue from the focused document.',
          retry: true,
          instead: 'model_status'
        )
      ensure
        @in_flight_id = nil
      end

      HOWTO_URI = 'skmcp://howto'
      HOWTO_TEXT = <<~MD.strip
        # SketchUp MCP

        One focused document. Call model_status first.

        - model_open opens or switches to an existing .skp
        - model_new makes a blank document
        - model_save uses mode in_place, save_as or copy
        - model_close closes; model_revert discards unsaved changes and reloads the last save, with no confirmation
        - execute_ruby does all modelling

        Unsaved changes on open, new or close need if_unsaved=save or if_unsaved=discard. Nothing is saved or discarded by default. save works only for a file this session opened or saved. A failure reply names next (what to call). temporary true means model_save with mode save_as and a path.

        SketchUp facts: transforms take radians (45.degrees). model.layers are tags. face.material= is the front, back_material= the back. Check valid? after erase. Use Sketchup.undo, not model.undo. vertex.position and nested bounds are local until multiplied by the parent transformation. Lengths are inches unless written like 10.m.
      MD

      def howto_listing
        { uri: HOWTO_URI, name: 'howto', mimeType: 'text/markdown' }
      end

      def read_resource(params, id)
        uri = params['uri'].to_s
        raise JsonRpc::ProtocolError.new(JsonRpc::INVALID_PARAMS, "Unknown resource: #{uri}", id: id) unless uri == HOWTO_URI

        { contents: [{ uri: HOWTO_URI, mimeType: 'text/markdown', text: HOWTO_TEXT }] }
      end

      def cancel(params)
        request_id = params.is_a?(Hash) ? params['requestId'] : nil
        return nil if request_id.nil?

        if same_rpc_id?(@in_flight_id, request_id)
          @call_gate.release if @call_gate
        end
        @on_cancel.call(request_id) if @on_cancel
        nil
      end

      def same_rpc_id?(left, right)
        !left.nil? && !right.nil? && (left == right || left.to_s == right.to_s)
      end
    end
  end
end
