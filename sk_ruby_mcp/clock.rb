# frozen_string_literal: true

module SkRubyMcp
  # Монотонные часы для дедлайнов и замеров: не зависят от перевода системного времени.
  # CLOCK_MONOTONIC есть в MRI 2.7 на Windows; запасной путь - на случай сборки SketchUp без него.
  module Clock
    def self.now
      if defined?(Process::CLOCK_MONOTONIC)
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      else
        Process.clock_gettime(Process::CLOCK_REALTIME)
      end
    rescue Errno::EINVAL, NotImplementedError
      Time.now.to_f
    end
  end
end
