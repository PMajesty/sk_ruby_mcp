# frozen_string_literal: true

require_relative 'test_helper'

class ArchitectMathTest < Minitest::Test
  MathN = SkRubyMcp::Runtime::ArchitectMath

  def test_metre_round_trip
    inches = MathN.m_to_in(10)
    assert_in_delta 393.7008, inches, 0.001
    assert_in_delta 10.0, MathN.in_to_m(inches), 1.0e-9
  end

  def test_storeys_guess_floors_a_slab
    assert_equal 6, MathN.storeys_guess(19.8, 3.3)
    assert_equal 1, MathN.storeys_guess(2.0, 3.3)
    assert_equal 1, MathN.storeys_guess(10, 0)
  end

  def test_facing_aliases
    assert_equal [0.0, -1.0, 0.0], MathN.facing_vector('south')
    assert_equal [0.0, -1.0, 0.0], MathN.facing_vector('S')
    assert_nil MathN.facing_vector('up')
  end

  def test_hex_color
    assert_equal [204, 102, 68], MathN.parse_hex_color('#CC6644')
    assert_equal [255, 0, 17], MathN.parse_hex_color('#F01')
    assert_nil MathN.parse_hex_color('red')
  end

  def test_grid_slots_even_gaps
    layout = MathN.grid_slots(
      face_w: 24.0, face_h: 33.0, cols: 8, rows: 9,
      win_w: 1.5, win_h: 1.6, sill: 3.3, margin: 0.4
    )
    assert layout['ok'], layout['message']
    assert_equal 72, layout['slots'].length
    first = layout['slots'].first
    assert first['u'] > 0.4
    assert_in_delta 3.3, first['v'], 1.0e-9
    last = layout['slots'].last
    assert last['u'] + last['w'] < 24.0
    assert last['v'] + last['h'] <= 33.0 - 0.4 + 1.0e-9
  end

  def test_grid_slots_honors_sill_exactly
    layout = MathN.grid_slots(
      face_w: 24.0, face_h: 33.0, cols: 8, rows: 9,
      win_w: 1.5, win_h: 1.6, sill: 4.2, margin: 0.4
    )
    assert layout['ok'], layout['message']
    first = layout['slots'].first
    last = layout['slots'].last
    assert_in_delta 4.2, first['v'], 1.0e-9
    assert last['v'] + last['h'] <= 33.0 - 0.4 + 1.0e-6
    refute_in_delta 5.6, first['v'], 0.05
  end

  def test_grid_slots_rejects_overflow
    layout = MathN.grid_slots(
      face_w: 10.0, face_h: 10.0, cols: 20, rows: 1,
      win_w: 1.5, win_h: 1.6, sill: 0.9, margin: 0.4
    )
    refute layout['ok']
    assert_equal 'does_not_fit', layout['error']
  end

  def test_slot_uv_is_relative_to_face_min_not_first_vertex
    u_min = MathN.m_to_in(-24.0)
    u0, v0, u1, _v1 = MathN.slot_uv_in(u_min, 0.0, 'u' => 0.4, 'v' => 3.3, 'w' => 1.5, 'h' => 1.6)
    assert_in_delta MathN.m_to_in(-23.6), u0, 0.01
    assert_in_delta MathN.m_to_in(-22.1), u1, 0.01
    assert_in_delta MathN.m_to_in(3.3), v0, 0.01
  end

  def test_perimeter_plan_does_not_double_corners
    plan = MathN.perimeter_plan(site_w: 70, site_d: 50, depth: 16, origin: [0, 0, 0])
    assert plan['ok'], plan['message']
    assert_equal 4, plan['wings'].length
    assert_in_delta 38.0, plan['courtyard_m'][0], 1.0e-9
    assert_in_delta 18.0, plan['courtyard_m'][1], 1.0e-9
    assert_in_delta 2816.0, plan['footprint_m2'], 1.0e-6
    assert_in_delta 3500.0, plan['site_m2'], 1.0e-6
    west = plan['wings'].find { |w| w['facing'] == 'west' }
    east = plan['wings'].find { |w| w['facing'] == 'east' }
    assert_equal [0.0, 16.0, 0.0], west['origin_m']
    assert_equal [16.0, 18.0], west['size_xy_m']
    assert_equal [54.0, 16.0, 0.0], east['origin_m']
  end

  def test_union_rects_l_shape_does_not_double_count
    south = [0.0, 0.0, 80.0, 18.0]
    west = [0.0, 0.0, 18.0, 40.0]
    union = MathN.union_rects_m2([south, west])
    assert_in_delta 1836.0, union, 1.0e-6
    assert_in_delta 2160.0, MathN.footprint_m2([80, 18]) + MathN.footprint_m2([18, 40]), 1.0e-6
  end

  def test_union_rects_disjoint
    a = [0.0, 0.0, 10.0, 10.0]
    b = [20.0, 0.0, 30.0, 10.0]
    assert_in_delta 200.0, MathN.union_rects_m2([a, b]), 1.0e-9
  end

  def test_perimeter_plan_rejects_solid_fill
    plan = MathN.perimeter_plan(site_w: 20, site_d: 20, depth: 10, origin: nil)
    refute plan['ok']
  end
end
