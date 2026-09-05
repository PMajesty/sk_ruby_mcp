# frozen_string_literal: true

module SchemaCheck
  module_function

  def valid?(schema, data)
    return false unless data.is_a?(Hash)
    return false unless schema.is_a?(Hash)

    Array(schema[:required] || schema['required']).each do |key|
      return false unless data.key?(key.to_s) || data.key?(key.to_sym)
    end
    properties = schema[:properties] || schema['properties'] || {}
    data.each do |key, value|
      spec = properties[key] || properties[key.to_s] || properties[key.to_sym]
      next unless spec

      type = spec[:type] || spec['type']
      return false unless type_match?(type, value)
    end
    true
  end

  def type_match?(type, value)
    return type.any? { |item| type_match?(item, value) } if type.is_a?(Array)

    case type
    when 'boolean' then value == true || value == false
    when 'string' then value.is_a?(String)
    when 'number' then value.is_a?(Numeric)
    when 'integer' then value.is_a?(Integer)
    when 'object' then value.is_a?(Hash)
    when 'array' then value.is_a?(Array)
    when 'null' then value.nil?
    else true
    end
  end
end
