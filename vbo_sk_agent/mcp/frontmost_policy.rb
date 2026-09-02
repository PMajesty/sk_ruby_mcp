# On macOS before SketchUp 2025.0, UI writes from a timer (selected_page= and
# similar) are no-ops until the window is key (SketchUp/api-issue-tracker#914).
# This policy decides when an MCP tools/call must wait for that frontmost state.
# ui_ready may be true, false, or nil (probe failed); only true means ready.

module VBO
  module SkAgent
    module McpFrontmost
      MAX_PENDING = 8
      MIN_WAIT = 1.0
      WAIT_TIMEOUT = 2.0

      class << self
        def wait_required?(platform:, version:)
          return false unless platform == :platform_osx

          number = version.to_s.to_f
          number.positive? && number < 25.0
        end

        def should_defer?(wait_required:, tool_call:, ui_ready:)
          wait_required && tool_call && ui_ready != true
        end

        def dispatch_ready?(waited:, ui_ready:, min_wait: MIN_WAIT, timeout: WAIT_TIMEOUT)
          return false if waited.nil?

          elapsed = waited.to_f
          return true if elapsed >= timeout.to_f

          elapsed >= min_wait.to_f && ui_ready == true
        end

        def queue_full?(size)
          size.to_i >= MAX_PENDING
        end
      end
    end
  end
end
