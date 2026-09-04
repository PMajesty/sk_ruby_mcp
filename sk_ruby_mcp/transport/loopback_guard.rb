# frozen_string_literal: true

module SkRubyMcp
  module Transport
    # Защита локального сервера: только loopback в Host, запрет чужих Origin (DNS rebinding),
    # необязательный общий секрет в заголовке Authorization.
    class LoopbackGuard
      LOOPBACK_HOST = /\A(127\.0\.0\.1|localhost|\[::1\])(:\d{1,5})?\z/i.freeze
      LOOPBACK_ORIGIN = %r{\Ahttps?://(127\.0\.0\.1|localhost|\[::1\])(:\d{1,5})?/?\z}i.freeze

      def initialize(token: '')
        @token = token.to_s
      end

      # nil, если запрос допустим; иначе готовый ответ с отказом.
      def check(request)
        headers = request.headers
        return forbid('Host is not loopback') unless LOOPBACK_HOST.match?(headers['host'].to_s.strip)

        origin = headers['origin']
        return forbid('Origin is not allowed') if origin && !LOOPBACK_ORIGIN.match?(origin.strip)
        return unauthorized unless authorized?(headers['authorization'])

        nil
      end

      private

      def authorized?(authorization)
        return true if @token.empty?

        authorization.to_s.strip == "Bearer #{@token}"
      end

      def forbid(message)
        HttpResponse.json(403, { error: message })
      end

      def unauthorized
        HttpResponse.json(401, { error: 'Bearer token required' }, headers: { 'WWW-Authenticate' => 'Bearer' })
      end
    end
  end
end
