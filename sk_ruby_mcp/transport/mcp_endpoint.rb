# frozen_string_literal: true

module SkRubyMcp
  module Transport
    # HTTP-обёртка над McpHandler по правилам Streamable HTTP без SSE и сессий:
    # запросы получают application/json, уведомления и ответы клиента получают 202 без тела.
    class McpEndpoint
      PROTOCOL_VERSION_HEADER = 'mcp-protocol-version'
      JSON_CONTENT_TYPE = %r{\Aapplication/json(\s*;.*)?\z}i.freeze
      BAD_REQUEST_CODES = [Protocol::JsonRpc::PARSE_ERROR, Protocol::JsonRpc::INVALID_REQUEST].freeze
      MAX_RESPONSE_BYTES = 1 * 1024 * 1024

      def initialize(handler:)
        @handler = handler
      end

      def call(request)
        type = request.headers['content-type'].to_s
        if !type.empty? && !JSON_CONTENT_TYPE.match?(type)
          return HttpResponse.json(415, { error: 'Content-Type must be application/json' })
        end

        version = request.headers[PROTOCOL_VERSION_HEADER]
        return unsupported_version(version) if version && !Protocol::McpHandler::SUPPORTED_PROTOCOL_VERSIONS.include?(version)

        response = @handler.handle(TextTrimmer.utf8(request.body))
        return wrap_deferred(response) if response.is_a?(Runtime::Deferred)
        return HttpResponse.empty(202) if response.nil?

        capped = cap_response(response)
        HttpResponse.json(http_status(capped), capped)
      end

      private

      def wrap_deferred(deferred)
        deferred.to_http = lambda { |payload|
          capped = cap_response(Protocol::JsonRpc.success(deferred.rpc_id, payload))
          HttpResponse.json(http_status(capped), capped)
        }
        deferred
      end

      def unsupported_version(version)
        error = Protocol::JsonRpc.error(nil, Protocol::JsonRpc::INVALID_REQUEST, "Unsupported MCP-Protocol-Version: #{version}")
        HttpResponse.json(400, error)
      end

      def cap_response(response)
        body = JSON.generate(response)
        return response if body.bytesize <= MAX_RESPONSE_BYTES
        return response unless response.is_a?(Hash) && response.key?(:result)

        Protocol::JsonRpc.success(
          response[:id],
          Tools::ToolReply.call(
            ok: false,
            error: 'response_too_large',
            message: 'The reply was too large. Ask for less data, a smaller execute_ruby return value, or model_look with a smaller width.',
            retry: true,
            instead: 'model_status'
          )
        )
      end

      def http_status(response)
        error = response[:error]
        error && BAD_REQUEST_CODES.include?(error[:code]) ? 400 : 200
      end
    end
  end
end
