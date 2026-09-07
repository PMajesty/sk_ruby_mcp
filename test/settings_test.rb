# frozen_string_literal: true

require_relative 'test_helper'

class SettingsTest < Minitest::Test
  Settings = SkRubyMcp::Settings

  def setup
    @store = {}
    @previous = TestSupport.replace_sketchup(TestSupport.sketchup_defaults_store(@store))
  end

  def teardown
    TestSupport.restore_sketchup(@previous)
  end

  def test_public_snapshot_redacts_a_set_token
    Settings.set('auth_token', 'secret')
    snapshot = Settings.public_snapshot
    assert_equal '(set)', snapshot['auth_token']
    refute_includes snapshot.values.map(&:to_s), 'secret'
  end

  def test_default_execution_timeout_is_thirty_seconds
    assert_equal 30.0, Settings::DEFAULTS['execution_timeout_s']
  end

  def test_zero_execution_timeout_falls_back_to_the_default
    assert_equal 30.0, Settings.send(:validate, 'execution_timeout_s', 0.0)
    assert_equal 30.0, Settings.send(:validate, 'execution_timeout_s', -1.0)
    assert_equal 12.0, Settings.send(:validate, 'execution_timeout_s', 12.0)
  end

  def test_packs_default_on
    assert_equal true, Settings::DEFAULTS['architect_pack']
    assert_equal true, Settings::DEFAULTS['facade_pack']
    assert_equal true, Settings.get('architect_pack')
    assert_equal true, Settings.get('facade_pack')
  end

  def test_public_snapshot_can_redact_a_given_hash
    published = Settings.public_snapshot('port' => 7891, 'auth_token' => 'secret')
    assert_equal '(set)', published['auth_token']
    assert_equal 7891, published['port']
  end

  def test_pack_flags_coerce_from_strings
    assert_equal false, Settings.set('architect_pack', 'false')
    assert_equal false, Settings.get('architect_pack')
    assert_equal true, Settings.set('facade_pack', 'TRUE')
    assert_equal true, Settings.get('facade_pack')
  end

  def test_interpret_rejects_out_of_range_and_non_numeric_port
    error = assert_raises(ArgumentError) { Settings.interpret('port', '80') }
    assert_includes error.message, '1024-65535'
    assert_raises(ArgumentError) { Settings.interpret('port', 'abc') }
    assert_equal 7892, Settings.interpret('port', '7892')
  end

  def test_interpret_rejects_out_of_range_timeout_and_pump
    assert_raises(ArgumentError) { Settings.interpret('execution_timeout_s', '0') }
    assert_raises(ArgumentError) { Settings.interpret('pump_interval', '2') }
    assert_in_delta 0.05, Settings.interpret('pump_interval', '0.05'), 1e-9
  end

  def test_set_still_coerces_an_invalid_port
    assert_equal 7891, Settings.set('port', '80')
    assert_equal 7891, Settings.get('port')
  end

  def test_runtime_slice_omits_auto_start
    snapshot = Settings.all
    refute_includes Settings.runtime_slice(snapshot).keys, 'auto_start'
    assert_includes Settings.runtime_slice(snapshot).keys, 'port'
  end
end
