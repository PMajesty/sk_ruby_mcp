# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Ответ, который допишет следующий тик: HTTP не спит, тик не блокируется.
    class Deferred
      attr_reader :deadline_at
      attr_accessor :rpc_id
      attr_writer :to_http

      def initialize(deadline_s:, poll:, timeout_result:)
        @deadline_at = Clock.now + deadline_s.to_f
        @poll = poll
        @timeout_result = timeout_result
        @gate = nil
        @to_http = nil
      end

      def http_payload(payload)
        return @to_http.call(payload) if @to_http

        payload
      end

      def attach_gate(gate)
        @gate = gate
        @gate.park if @gate
      end

      def gated?
        !@gate.nil?
      end

      def release_gate
        @gate.release if @gate
        @gate = nil
      end

      def abandon_wait
        release_gate
        @timeout_result.call
      end

      def resolve(now = Clock.now)
        reply = @poll.call
        if reply
          release_gate
          return reply
        end
        if now >= @deadline_at
          release_gate
          return @timeout_result.call
        end

        nil
      rescue StandardError, ScriptError
        release_gate
        raise
      end
    end
  end
end
