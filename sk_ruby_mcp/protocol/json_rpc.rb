# frozen_string_literal: true

require 'json'

module SkRubyMcp
  module Protocol
    # Конверты JSON-RPC 2.0: разбор входящего сообщения и сборка ответов.
    module JsonRpc
      VERSION = '2.0'
      PARSE_ERROR = -32_700
      INVALID_REQUEST = -32_600
      METHOD_NOT_FOUND = -32_601
      INVALID_PARAMS = -32_602
      INTERNAL_ERROR = -32_603
      MAX_ERROR_DETAIL_LENGTH = 200

      Message = Struct.new(:id, :method, :params, :id_present, keyword_init: true) do
        def request?
          !method.nil? && id_present
        end

        def notification?
          !method.nil? && !id_present
        end

        # Ответ клиента на серверный запрос: сервер запросов не посылает, такие сообщения игнорируются.
        def response?
          method.nil?
        end
      end

      class ProtocolError < StandardError
        attr_reader :code, :id

        def initialize(code, message, id: nil)
          super(message)
          @code = code
          @id = id
        end
      end

      class << self
        def parse(body)
          data = JSON.parse(body.to_s)
        rescue JSON::ParserError
          raise ProtocolError.new(PARSE_ERROR, 'Parse error')
        else
          validate(data)
        end

        def success(id, result)
          { jsonrpc: VERSION, id: id, result: result }
        end

        def error(id, code, message, data = nil)
          payload = { code: code, message: message }
          payload[:data] = data unless data.nil?
          { jsonrpc: VERSION, id: id, error: payload }
        end

        private

        def validate(data)
          raise ProtocolError.new(INVALID_REQUEST, 'Batch requests are not supported') if data.is_a?(Array)
          raise ProtocolError.new(INVALID_REQUEST, 'Request must be a JSON object') unless data.is_a?(Hash)

          id_present = data.key?('id')
          id = data['id']
          raise ProtocolError.new(INVALID_REQUEST, 'id must be a string, a number or null') unless valid_id?(id)
          raise ProtocolError.new(INVALID_REQUEST, 'jsonrpc must be "2.0"', id: id) unless data['jsonrpc'] == VERSION

          validate_method(data, id) if data.key?('method')
          Message.new(id: id, method: data['method'], params: data['params'], id_present: id_present)
        end

        def valid_id?(id)
          id.nil? || id.is_a?(String) || id.is_a?(Numeric)
        end

        def validate_method(data, id)
          raise ProtocolError.new(INVALID_REQUEST, 'method must be a string', id: id) unless data['method'].is_a?(String)

          params = data['params']
          raise ProtocolError.new(INVALID_REQUEST, 'params must be an object', id: id) unless params.nil? || params.is_a?(Hash)
        end
      end
    end
  end
end
