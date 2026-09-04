# frozen_string_literal: true

module SkRubyMcp
  module Protocol
    # Методы MCP поверх JSON-RPC: initialize, ping, tools/list, tools/call.
    # Сервер не объявляет resources и prompts, но отвечает на их list пустыми списками:
    # некоторые клиенты вызывают их независимо от capabilities.
    class McpHandler
      LATEST_PROTOCOL_VERSION = '2025-11-25'
      SUPPORTED_PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze

      def initialize(tools:, server_info:, instructions:)
        @tools = tools.each_with_object({}) { |tool, by_name| by_name[tool.name] = tool }.freeze
        @server_info = server_info
        @instructions = instructions
        @tools_list_result = { tools: tools.map(&:spec) }.freeze
      end

      # Hash ответа или nil, если ответ не нужен (уведомление либо ответ клиента).
      def handle(body)
        message = JsonRpc.parse(body)
        return nil unless message.request?

        JsonRpc.success(message.id, dispatch(message))
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
        when 'resources/list' then { resources: [] }
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
          capabilities: { tools: {} },
          serverInfo: @server_info,
          instructions: @instructions
        }
      end

      def call_tool(params, id)
        tool = @tools[params['name'].to_s]
        raise JsonRpc::ProtocolError.new(JsonRpc::INVALID_PARAMS, "Unknown tool: #{params['name']}", id: id) unless tool

        arguments = params['arguments']
        tool.call(arguments.is_a?(Hash) ? arguments : {})
      end
    end
  end
end
