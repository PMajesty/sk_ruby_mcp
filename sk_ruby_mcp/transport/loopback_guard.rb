# frozen_string_literal: true

require 'uri'

module SkRubyMcp
  module Transport
    # Защита локального сервера: loopback Host, Origin по спецификации MCP, необязательный токен.
    class LoopbackGuard
      LOOPBACK_HOST = /\A(127\.0\.0\.1|localhost|\[::1\]|::1)(:\d{1,5})?\z/i.freeze
      LOOPBACK_ORIGIN_HOSTS = %w[127.0.0.1 localhost ::1 [::1]].freeze

      def initialize(token: '')
        @token = token.to_s
      end

      def check(request)
        headers = request.headers
        return forbid('Host is not loopback') unless LOOPBACK_HOST.match?(headers['host'].to_s.strip)

        origin = headers['origin'].to_s.strip
        return forbid('Origin is not allowed') unless origin_allowed?(origin)
        return unauthorized unless authorized?(headers['authorization'])

        nil
      end

      private

      def origin_allowed?(origin)
        return true if origin.empty?

        uri = URI.parse(origin)
        return false unless uri.scheme.to_s.downcase == 'http'
        return false unless LOOPBACK_ORIGIN_HOSTS.include?(uri.host.to_s.downcase)

        true
      rescue URI::InvalidURIError
        false
      end

      def authorized?(authorization)
        return true if @token.empty?

        authorization.to_s.strip == "Bearer #{@token}"
      end

      def forbid(message)
        HttpResponse.json(
          403,
          {
            error: message,
            next: forbid_next(message)
          }
        )
      end

      def forbid_next(message)
        if message.to_s.include?('Origin')
          'Use a loopback http Origin, or omit Origin. HTTP is up; this is not a SketchUp crash.'
        else
          'Use Host 127.0.0.1, localhost, or ::1. HTTP is up; this is not a SketchUp crash.'
        end
      end

      def unauthorized
        HttpResponse.json(
          401,
          {
            error: 'Bearer token required',
            next: 'Send Authorization: Bearer <token>. A token is configured. HTTP is up; this is not a SketchUp crash.'
          },
          headers: { 'WWW-Authenticate' => 'Bearer' }
        )
      end
    end
  end
end
