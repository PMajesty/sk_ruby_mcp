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
      'execution_timeout_s' => 30.0
    }.freeze
    PORT_RANGE = (1024..65_535).freeze
    MIN_PUMP_INTERVAL = 0.01
    MAX_PUMP_INTERVAL = 1.0
    MIN_EXECUTION_TIMEOUT_S = 0.05
    MAX_EXECUTION_TIMEOUT_S = 3600.0

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

      def all
        DEFAULTS.keys.each_with_object({}) { |key, snapshot| snapshot[key] = get(key) }
      end

      def public_snapshot
        snapshot = all
        token = snapshot['auth_token'].to_s
        snapshot['auth_token'] = token.empty? ? '' : '(set)'
        snapshot
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
    end
  end
end
