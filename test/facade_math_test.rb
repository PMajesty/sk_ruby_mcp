# frozen_string_literal: true

require_relative 'test_helper'

class FacadeMathTest < Minitest::Test
  FM = SkRubyMcp::Runtime::FacadeMath

  def test_camera_basis_is_orthonormal_and_right_handed
    basis = FM.camera_basis([0.0, 0.0, 0.0], [0.0, 10.0, 0.0], [0.0, 0.0, 1.0])
    assert_in_delta 1.0, basis[:forward][1], 1e-9
    assert_in_delta 1.0, basis[:right][0], 1e-9
    assert_in_delta 1.0, basis[:up][2], 1e-9
    assert_in_delta 0.0, FM.dot3(basis[:right], basis[:up]), 1e-9
  end

  def test_project_puts_the_target_at_the_image_center_and_right_is_right
    eye = [0.0, 0.0, 0.0]
    basis = FM.camera_basis(eye, [0.0, 100.0, 0.0], [0.0, 0.0, 1.0])
    focal = FM.focal_px(30.0, 800, 600, true)
    center = FM.project(basis, eye, [0.0, 100.0, 0.0], 800, 600, focal)
    assert_in_delta 400.0, center[0], 1e-6
    assert_in_delta 300.0, center[1], 1e-6
    right = FM.project(basis, eye, [10.0, 100.0, 5.0], 800, 600, focal)
    assert right[0] > 400.0
    assert right[1] < 300.0
    assert_nil FM.project(basis, eye, [0.0, -5.0, 0.0], 800, 600, focal)
  end

  def test_focal_uses_height_when_fov_is_vertical
    tall = FM.focal_px(15.69, 3072, 1999, true)
    wide = FM.focal_px(15.69, 3072, 1999, false)
    assert_in_delta (1999 / 2.0) / Math.tan(15.69 * Math::PI / 360.0), tall, 1e-6
    assert wide > tall
    assert_nil FM.focal_px(0.0, 100, 100, true)
  end

  def test_frame_axes_run_left_to_right_for_a_viewer_outside
    right, up = FM.frame_axes([0.0, -1.0, 0.0])
    assert_in_delta 1.0, right[0], 1e-9
    assert_in_delta 1.0, up[2], 1e-9
    right_east, = FM.frame_axes([1.0, 0.0, 0.0])
    assert_in_delta 1.0, right_east[1], 1e-9
    right_north, = FM.frame_axes([0.0, 1.0, 0.0])
    assert_in_delta(-1.0, right_north[0], 1e-9)
    assert_nil FM.frame_axes([0.0, 0.0, 0.0])
  end

  def test_storey_cells_from_plates_and_fallback_height
    cells = FM.storey_cells(0.0, 10.0, [3.3, 6.6, 9.8, -1.0, 10.0])
    assert_equal [[0.0, 3.3], [3.3, 6.6], [6.6, 10.0]], cells.map { |c| [c['z0_m'], c['z1_m']] }
    assert_equal [0, 1, 2], cells.map { |c| c['index'] }
    fallback = FM.storey_cells(0.0, 10.0, [], storey_h_m: 3.0)
    assert_equal [[0.0, 3.0], [3.0, 6.0], [6.0, 10.0]], fallback.map { |c| [c['z0_m'], c['z1_m']] }
    assert_empty FM.storey_cells(0.0, 0.5, [])
  end

  def face_table
    { '11' => { 'width_m' => 20.0, 'cells' => FM.storey_cells(0.0, 10.0, [3.3, 6.6]) } }
  end

  def face_public
    { 'width_m' => 20.0, 'height_m' => 10.0, 'z0_m' => 0.0, 'z1_m' => 10.0 }
  end

  def test_expand_spreads_count_inside_the_span_and_repeats_storeys
    plan = FM.expand_items(
      [{ 'face' => 11, 'x0' => 0.1, 'x1' => 0.9, 'count' => 3, 'width_m' => 1.5, 'storeys' => 'all' }],
      {},
      face_table
    )
    assert_empty plan['errors']
    assert_equal 9, plan['items'].length
    first = plan['items'].first
    resolved = FM.resolve_opening(first, face_public, face_table['11']['cells'])
    assert resolved['ok'], resolved.inspect
    assert_in_delta 4.875, resolved['u0_m'], 1e-3
    assert_in_delta 1.5, resolved['width_m'], 1e-3
    assert_in_delta 0.825, resolved['z0_m'], 1e-3
    assert_in_delta 3.3, resolved['z1_m'], 1e-3
    assert_equal %w[left right bottom], resolved['frame_edges']
  end

  def test_item_storey_beats_default_storeys
    plan = FM.expand_items([{ 'face' => 11, 'x0' => 0.2, 'x1' => 0.4, 'storey' => 2 }], { 'storeys' => 'all' }, face_table)
    assert_equal [2], plan['items'].map { |p| p['storey'] }
  end

  def test_count_without_span_is_an_error
    plan = FM.expand_items([{ 'face' => 11, 'u0_m' => 1.0, 'width_m' => 1.0, 'count' => 3, 'storey' => 0 }], {}, face_table)
    assert_empty plan['items']
    assert_match(/x0\.\.x1 span/, plan['errors'].first['error'])
  end

  def test_kind_defaults_and_explicit_metres
    cells = face_table['11']['cells']
    door = FM.resolve_opening({ 'face' => 11, 'kind' => 'glass_door', 'u0_m' => 2.0, 'width_m' => 1.2, 'storey' => 0 }.merge(FM::OPENING_DEFAULTS.merge('kind' => 'glass_door')), face_public, cells)
    assert door['ok'], door.inspect
    assert_in_delta 0.0, door['z0_m'], 1e-6
    assert_in_delta 3.3 * 0.66, door['z1_m'], 1e-6
    assert_equal %w[left right top], door['frame_edges']

    custom = FM.resolve_opening(FM::OPENING_DEFAULTS.merge('face' => 11, 'kind' => 'custom', 'x0' => 0.5, 'x1' => 0.6, 'storey' => 1), face_public, cells)
    refute custom['ok']
    assert_match(/custom kind needs/, custom['error'])

    sill = FM.resolve_opening(FM::OPENING_DEFAULTS.merge('face' => 11, 'kind' => 'custom', 'x0' => 0.5, 'x1' => 0.6, 'storey' => 1, 'sill_m' => 0.9, 'head_m' => 2.4), face_public, cells)
    assert sill['ok'], sill.inspect
    assert_in_delta 3.3 + 0.9, sill['z0_m'], 1e-6
    assert_in_delta 3.3 + 2.4, sill['z1_m'], 1e-6
  end

  def test_resolve_rejects_outside_bad_kind_and_bad_edges
    cells = face_table['11']['cells']
    outside = FM.resolve_opening(FM::OPENING_DEFAULTS.merge('face' => 11, 'x0' => 0.9, 'x1' => 1.2, 'storey' => 0), face_public, cells)
    assert_match(/outside the face horizontally/, outside['error'])
    world = FM.resolve_opening(FM::OPENING_DEFAULTS.merge('face' => 11, 'x0' => 0.1, 'x1' => 0.2, 'z0_m' => 8.0, 'z1_m' => 12.0), face_public, cells)
    assert_match(/outside the face vertically/, world['error'])
    kind = FM.resolve_opening(FM::OPENING_DEFAULTS.merge('face' => 11, 'kind' => 'porthole', 'x0' => 0.1, 'x1' => 0.2, 'storey' => 0), face_public, cells)
    assert_match(/kind must be one of/, kind['error'])
    edges = FM.resolve_opening(FM::OPENING_DEFAULTS.merge('face' => 11, 'x0' => 0.1, 'x1' => 0.2, 'storey' => 0, 'frame_edges' => %w[left diagonal]), face_public, cells)
    assert_match(/frame_edges must be a subset/, edges['error'])
    missing_storey = FM.resolve_opening(FM::OPENING_DEFAULTS.merge('face' => 11, 'x0' => 0.1, 'x1' => 0.2, 'storey' => 7), face_public, cells)
    assert_match(/storey 7 does not exist/, missing_storey['error'])
  end

  def test_diff_reports_matched_mismatched_missing_and_extra
    want = [
      { 'face' => '11', 'kind' => 'small_window', 'u0_m' => 2.0, 'width_m' => 1.5, 'z0_m' => 4.0, 'z1_m' => 6.0 },
      { 'face' => '11', 'kind' => 'small_window', 'u0_m' => 6.0, 'width_m' => 1.5, 'z0_m' => 4.0, 'z1_m' => 6.0 },
      { 'face' => '11', 'kind' => 'glass_door', 'u0_m' => 10.0, 'width_m' => 1.2, 'z0_m' => 0.0, 'z1_m' => 2.2 }
    ]
    have = [
      { 'id' => 1, 'face' => '11', 'kind' => 'small_window', 'u0_m' => 2.05, 'width_m' => 1.5, 'z0_m' => 4.0, 'z1_m' => 6.0 },
      { 'id' => 2, 'face' => '11', 'kind' => 'small_window', 'u0_m' => 6.6, 'width_m' => 1.5, 'z0_m' => 4.0, 'z1_m' => 6.0 },
      { 'id' => 3, 'face' => '11', 'kind' => 'small_window', 'u0_m' => 15.0, 'width_m' => 1.5, 'z0_m' => 4.0, 'z1_m' => 6.0 }
    ]
    report = FM.diff(want, have, tol_m: 0.15)
    refute report['ok']
    assert_equal 1, report['matched']
    assert_equal 1, report['mismatched'].length
    assert_in_delta 0.6, report['mismatched'].first['delta']['u0_m'], 1e-6
    assert_equal 1, report['missing'].length
    assert_equal 'glass_door', report['missing'].first['kind']
    assert_equal [3], report['extra'].map { |row| row['id'] }
    assert FM.diff(want.first(1), have.first(1), tol_m: 0.15)['ok']
  end

  def test_columns_that_do_not_fit_are_an_item_error
    plan = FM.expand_items([{ 'face' => 11, 'x0' => 0.0, 'x1' => 0.5, 'count' => 3, 'width_m' => 4.0, 'storey' => 0 }], {}, face_table)
    assert_empty plan['items']
    assert_match(/3 openings of 20.0% each do not fit into x0..x1 \(50.0% of the face\)/, plan['errors'].first['error'])
    reversed = FM.expand_items([{ 'face' => 11, 'x0' => 0.6, 'x1' => 0.5, 'count' => 2, 'storey' => 0 }], {}, face_table)
    assert_match(/x1 must be greater than x0/, reversed['errors'].first['error'])
  end

  def test_overlaps_are_detected_and_rejected_in_order
    a = { 'face' => '11', 'item' => 0, 'column' => 0, 'u0_m' => 1.0, 'u1_m' => 2.5, 'z0_m' => 4.0, 'z1_m' => 6.0 }
    touching = { 'face' => '11', 'item' => 1, 'u0_m' => 2.5, 'u1_m' => 4.0, 'z0_m' => 4.0, 'z1_m' => 6.0 }
    crossing = { 'face' => '11', 'item' => 2, 'u0_m' => 2.0, 'u1_m' => 3.0, 'z0_m' => 5.0, 'z1_m' => 7.0 }
    other_face = { 'face' => '12', 'item' => 3, 'u0_m' => 1.0, 'u1_m' => 2.5, 'z0_m' => 4.0, 'z1_m' => 6.0 }
    above = { 'face' => '11', 'item' => 4, 'u0_m' => 1.0, 'u1_m' => 2.5, 'z0_m' => 6.0, 'z1_m' => 8.0 }
    refute FM.overlap?(a, touching)
    assert FM.overlap?(a, crossing)
    refute FM.overlap?(a, other_face)
    refute FM.overlap?(a, above)

    live = [{ 'id' => 77, 'face' => '11', 'u0_m' => 10.0, 'width_m' => 1.5, 'z0_m' => 4.0, 'z1_m' => 6.0 }]
    late = { 'face' => '11', 'item' => 5, 'u0_m' => 11.0, 'u1_m' => 12.0, 'z0_m' => 4.5, 'z1_m' => 5.5 }
    fit = FM.reject_overlaps([a, touching, crossing, late], live)
    assert_equal [0, 1], fit['accepted'].map { |row| row['item'] }
    assert_equal ['overlaps item 0 column 0 on face 11', 'overlaps existing opening 77 on face 11'], fit['errors'].map { |row| row['error'] }
  end

  def test_id_colors_are_distinct_and_never_black
    colors = (0...80).map { |i| FM.id_color(i) }
    assert_equal 80, colors.uniq.length
    refute_includes colors, [0, 0, 0]
    colors.each { |rgb| rgb.each { |c| assert_includes FM::ID_LEVELS, c } }
  end
end
