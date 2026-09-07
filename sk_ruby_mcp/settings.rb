# frozen_string_literal: true

module SkRubyMcp
  # Настройки расширения поверх Sketchup.read_default / write_default.
  # Значения хранятся строками и приводятся к типу значения по умолчанию.
  module Settings
    SECTION = 'SkRubyMcp'
    DEFAULTS = {
      'port' => 7891,
      'auto_start' => true,
      'pump_interval' => 0.02,
      'auth_token' => '',
      'wrap_in_operation' => true,
      'execution_timeout_s' => 30.0,
      'architect_pack' => true,
      'facade_pack' => true
    }.freeze
    PORT_RANGE = (1024..65_535).freeze
    MIN_PUMP_INTERVAL = 0.01
    MAX_PUMP_INTERVAL = 1.0
    MIN_EXECUTION_TIMEOUT_S = 0.05
    MAX_EXECUTION_TIMEOUT_S = 3600.0
    RUNTIME_KEYS = %w[
      port pump_interval auth_token wrap_in_operation execution_timeout_s
      architect_pack facade_pack
    ].freeze

    class << self
      def get(key)
        default = fetch_default(key)
        stored = Sketchup.read_default(SECTION, key)
        validate(key, stored.nil? ? default : coerce(stored, default))
      end

      def set(key, value)
        accepted = validate(key, coerce(value, fetch_default(key)))
        Sketchup.write_default(SECTION, key, accepted.to_s)
        accepted
      end

      def interpret(key, raw)
        default = fetch_default(key)
        case default
        when true, false then interpret_boolean(key, raw)
        when Integer then interpret_integer(key, raw)
        when Float then interpret_float(key, raw)
        else raw.to_s
        end
      end

      def all
        DEFAULTS.keys.each_with_object({}) { |key, snapshot| snapshot[key] = get(key) }
      end

      def public_snapshot(snapshot = all)
        published = snapshot.dup
        token = published['auth_token'].to_s
        published['auth_token'] = token.empty? ? '' : '(set)'
        published
      end

      def runtime_slice(snapshot = all)
        RUNTIME_KEYS.each_with_object({}) { |key, published| published[key] = snapshot[key] }
      end

      private

      def fetch_default(key)
        DEFAULTS.fetch(key) { raise ArgumentError, "unknown setting: #{key.inspect}" }
      end

      def coerce(raw, default)
        case default
        when true, false then raw.to_s.strip.downcase == 'true'
        when Float then Float(raw.to_s)
        when Integer then Integer(raw.to_s, 10)
        else raw.to_s
        end
      rescue ArgumentError, TypeError
        default
      end

      def validate(key, value)
        case key
        when 'port' then PORT_RANGE.cover?(value) ? value : DEFAULTS['port']
        when 'pump_interval' then value.clamp(MIN_PUMP_INTERVAL, MAX_PUMP_INTERVAL)
        when 'execution_timeout_s'
          value.positive? ? value.clamp(MIN_EXECUTION_TIMEOUT_S, MAX_EXECUTION_TIMEOUT_S) : DEFAULTS['execution_timeout_s']
        else value
        end
      end

      def interpret_boolean(key, raw)
        return raw if raw == true || raw == false

        text = raw.to_s.strip.downcase
        unless text == 'true' || text == 'false'
          raise ArgumentError, "#{key} must be true or false"
        end

        text == 'true'
      end

      def interpret_integer(key, raw)
        text = raw.is_a?(String) ? raw.strip : raw
        unless text.is_a?(Integer) || (text.is_a?(String) && text.match?(/\A-?\d+\z/))
          raise ArgumentError, "#{key} must be an integer"
        end

        value = Integer(text)
        if key == 'port' && !PORT_RANGE.cover?(value)
          raise ArgumentError, "#{key} must be #{PORT_RANGE.min}-#{PORT_RANGE.max}"
        end

        value
      end

      def interpret_float(key, raw)
        value = if raw.is_a?(Numeric)
                  raw.to_f
                else
                  text = raw.to_s.strip
                  unless text.match?(/\A-?\d+(\.\d+)?\z/)
                    raise ArgumentError, "#{key} must be a number"
                  end

                  Float(text)
                end
        lo, hi = float_bounds(key)
        unless (lo..hi).cover?(value)
          raise ArgumentError, "#{key} must be #{lo}-#{hi}"
        end

        value
      end

      def float_bounds(key)
        case key
        when 'pump_interval' then [MIN_PUMP_INTERVAL, MAX_PUMP_INTERVAL]
        when 'execution_timeout_s' then [MIN_EXECUTION_TIMEOUT_S, MAX_EXECUTION_TIMEOUT_S]
        else [0.0, Float::INFINITY]
        end
      end
    end
  end
end
