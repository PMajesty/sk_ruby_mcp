# frozen_string_literal: true

require_relative 'test_helper'

class SchemaAdvertiserTest < Minitest::Test
  Advertiser = SkRubyMcp::Tools::SchemaAdvertiser

  def test_collapses_string_integer_and_string_null_unions
    spec = Advertiser.advertise(
      inputSchema: {
        type: 'object',
        properties: {
          faces: { type: %w[string integer] },
          path: { type: %w[string null] }
        }
      }
    )
    assert_equal 'string', spec[:inputSchema][:properties][:faces][:type]
    assert_equal 'string', spec[:inputSchema][:properties][:path][:type]
  end

  def test_open_objects_gain_an_empty_properties_map
    spec = Advertiser.advertise(
      inputSchema: { type: 'object', additionalProperties: true }
    )
    assert_equal({}, spec[:inputSchema][:properties])
    assert_equal true, spec[:inputSchema][:additionalProperties]
  end

  def test_plain_object_without_additional_properties_is_left_alone
    schema = { type: 'object' }
    spec = Advertiser.advertise(inputSchema: schema)
    refute spec[:inputSchema].key?(:properties)
  end

  def test_long_descriptions_are_clipped_to_1024
    long = 'word ' * 400
    spec = Advertiser.advertise(description: long)
    assert spec[:description].length <= Advertiser::MAX_DESCRIPTION
    assert spec[:description].end_with?('...')
  end

  def test_does_not_mutate_the_source_spec
    source = { description: 'keep', inputSchema: { type: %w[string integer] } }
    Advertiser.advertise(source)
    assert_equal %w[string integer], source[:inputSchema][:type]
  end
end
