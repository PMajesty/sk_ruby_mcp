# frozen_string_literal: true

require_relative 'test_helper'

class ClockTest < Minitest::Test
  def test_now_is_a_non_decreasing_numeric
    first = SkRubyMcp::Clock.now
    second = SkRubyMcp::Clock.now
    assert_kind_of Numeric, first
    assert second >= first
  end
end
