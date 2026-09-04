# frozen_string_literal: true

module SkRubyMcp
  module Transport
    # HTTP-обёртка над McpHandler по правилам Streamable HTTP без SSE и сессий:
    # запросы получают application/json, уведомления и ответы клиента получают 202 без тела.
    class McpEndpoint
      PROTOCOL_VERSION_HEADER = 'mcp-protocol-version'
      BAD_REQUEST_CODES = [Protocol::JsonRpc::PARSE_ERROR, Protocol::JsonRpc::INVALID_REQUEST].freeze

      def initialize(handler:)
        @handler = handler
      end

      def call(request)
        version = request.headers[PROTOCOL_VERSION_HEADER]
        return unsupported_version(version) if version && !Protocol::McpHandler::SUPPORTED_PROTOCOL_VERSIONS.include?(version)

        response = @handler.handle(TextTrimmer.utf8(request.body))
        return HttpResponse.empty(202) if response.nil?

        HttpResponse.json(http_status(response), response)
      end

      private

      def unsupported_version(version)
        error = Protocol::JsonRpc.error(nil, Protocol::JsonRpc::INVALID_REQUEST, "Unsupported MCP-Protocol-Version: #{version}")
        HttpResponse.json(400, error)
      end

      def http_status(response)
        error = response[:error]
        error && BAD_REQUEST_CODES.include?(error[:code]) ? 400 : 200
      end
    end
  end
end
