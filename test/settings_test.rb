# frozen_string_literal: true

require_relative 'test_helper'

class SettingsTest < Minitest::Test
  Settings = SkRubyMcp::Settings

  def setup
    @store = {}
    sketchup = Object.new
    store = @store
    sketchup.define_singleton_method(:read_default) { |_section, key| store[key] }
    sketchup.define_singleton_method(:write_default) { |_section, key, value| store[key] = value }
    @previous = Object.const_get(:Sketchup) if Object.const_defined?(:Sketchup)
    Object.send(:remove_const, :Sketchup) if Object.const_defined?(:Sketchup)
    Object.const_set(:Sketchup, sketchup)
  end

  def teardown
    Object.send(:remove_const, :Sketchup) if Object.const_defined?(:Sketchup)
    Object.const_set(:Sketchup, @previous) if @previous
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
end
