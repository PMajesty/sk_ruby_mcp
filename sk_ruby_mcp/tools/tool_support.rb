# frozen_string_literal: true

require 'json'

module SkRubyMcp
  module Tools
    module ArgumentGuard
      MAX_UNKNOWN_KEYS = 8

      module_function

      def unknown_message(arguments, allowed_keys)
        arguments = {} unless arguments.is_a?(Hash)
        unknown = arguments.keys.map(&:to_s).uniq.sort - allowed_keys.map(&:to_s)
        return nil if unknown.empty?

        listed = unknown[0, MAX_UNKNOWN_KEYS]
        suffix = unknown.size > MAX_UNKNOWN_KEYS ? ", +#{unknown.size - MAX_UNKNOWN_KEYS} more" : ''
        "unknown arguments: #{listed.join(', ')}#{suffix}"
      end
    end

    # JSON-ответ инструмента: structuredContent и текстовый близнец.
    module ToolReply
      GATE_BUSY = {
        'ok' => false,
        'error' => 'busy',
        'message' => 'Another tool is using SketchUp.',
        'retry' => true,
        'next' => 'Wait a moment and call again.'
      }.freeze
      KEEP_NIL_KEYS = %w[path].freeze

      module_function

      def call(payload, extra_content = nil)
        compact = compact_hash(payload)
        content = [{ type: 'text', text: JSON.pretty_generate(compact) }]
        Array(extra_content).each { |item| content << item }
        {
          content: content,
          structuredContent: compact,
          isError: compact['ok'] == false
        }
      end

      def compact_hash(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), collected|
            key_name = key.to_s
            next if item.nil? && !KEEP_NIL_KEYS.include?(key_name)

            collected[key_name] = compact_hash(item)
          end
        when Array
          value.map { |item| compact_hash(item) }
        else
          value
        end
      end
    end

    DOCUMENT_OUTPUT_SCHEMA = {
      type: 'object',
      properties: {
        ok: { type: 'boolean' },
        state: { type: 'string', enum: %w[active no_document opening failed] },
        changed: { type: 'string' },
        path: { type: %w[string null] },
        path_requested: { type: 'string' },
        title: { type: 'string' },
        modified: { type: 'boolean' },
        temporary: { type: 'boolean' },
        copy_path: { type: 'string' },
        scope_reset: { type: 'boolean' },
        model: { type: 'object' },
        host: { type: 'object' },
        next: { type: 'string' },
        error: { type: 'string' },
        message: { type: 'string' },
        retry: { type: 'boolean' },
        instead: { type: 'string' }
      },
      required: ['ok']
    }.freeze

    EXECUTE_OUTPUT_SCHEMA = {
      type: 'object',
      properties: {
        ok: { type: 'boolean' },
        return_value: { type: 'string' },
        stdout: { type: 'string' },
        stderr: { type: 'string' },
        truncated: { type: 'boolean' },
        elapsed_ms: { type: 'number' },
        undo_step: { type: 'string' },
        edit_context: { type: 'string' },
        path: { type: %w[string null] },
        title: { type: 'string' },
        scope_reset: { type: 'boolean' },
        error: { type: 'string' },
        message: { type: 'string' },
        retry: { type: 'boolean' },
        instead: { type: 'string' },
        next: { type: 'string' },
        ruby: { type: 'object' },
        timed_out: { type: 'object' }
      },
      required: ['ok']
    }.freeze

    LOOK_OUTPUT_SCHEMA = {
      type: 'object',
      properties: {
        ok: { type: 'boolean' },
        state: { type: 'string', enum: %w[active no_document opening failed] },
        path: { type: %w[string null] },
        title: { type: 'string' },
        view: { type: 'string', enum: %w[current iso plan front right] },
        width: { type: 'integer' },
        height: { type: 'integer' },
        mime: { type: 'string' },
        bytes: { type: 'integer' },
        camera: { type: 'object' },
        error: { type: 'string' },
        message: { type: 'string' },
        retry: { type: 'boolean' },
        instead: { type: 'string' },
        next: { type: 'string' }
      },
      required: ['ok']
    }.freeze
  end
end
