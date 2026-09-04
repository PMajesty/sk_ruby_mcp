# frozen_string_literal: true

module SkRubyMcp
  # Монотонные часы для дедлайнов и замеров: не зависят от перевода системного времени.
  module Clock
    def self.now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
