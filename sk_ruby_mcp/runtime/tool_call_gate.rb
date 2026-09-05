# frozen_string_literal: true

module SkRubyMcp
  module Runtime
    # Один мутирующий tools/call на тик. Вложенный тик не должен запускать второй вызов.
    class ToolCallGate
      def initialize
        @mutating = false
        @parked = false
      end

      def begin_tick
        @mutating = false unless @parked
      end

      def release
        @parked = false
        @mutating = false
      end

      def parked?
        @parked
      end

      def park
        @parked = true
        @mutating = true
      end

      def try_mutating
        return false if @mutating

        @mutating = true
        true
      end
    end
  end
end
