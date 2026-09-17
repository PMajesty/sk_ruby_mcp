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

    # Копия spec для tools/list: без union-типов и описаний длиннее лимита провайдеров.
    module SchemaAdvertiser
      MAX_DESCRIPTION = 1024
      ELLIPSIS = '...'

      module_function

      def advertise(spec)
        return spec unless spec.is_a?(Hash)

        walk(dup_node(spec))
      end

      def dup_node(node)
        case node
        when Hash
          node.each_with_object({}) { |(key, value), copy| copy[key] = dup_node(value) }
        when Array
          node.map { |value| dup_node(value) }
        else
          node
        end
      end

      def walk(node)
        case node
        when Hash
          collapse_type!(node)
          ensure_object_properties!(node)
          clip_description_fields!(node)
          node.each_value { |value| walk(value) }
          node
        when Array
          node.each { |value| walk(value) }
          node
        else
          node
        end
      end

      def collapse_type!(node)
        type = node[:type] || node['type']
        return unless type.is_a?(Array)

        names = type.map(&:to_s).sort
        replacement =
          if names == %w[integer string]
            'string'
          elsif names == %w[null string]
            'string'
          end
        return unless replacement

        if node.key?(:type)
          node[:type] = replacement
        else
          node['type'] = replacement
        end
      end

      def ensure_object_properties!(node)
        type = node[:type] || node['type']
        object_type = type == 'object' || (type.is_a?(Array) && type.map(&:to_s).include?('object'))
        return unless object_type
        return unless additional_properties_open?(node)
        return if node.key?(:properties) || node.key?('properties')

        if symbol_keys?(node)
          node[:properties] = {}
        else
          node['properties'] = {}
        end
      end

      def additional_properties_open?(node)
        if node.key?(:additionalProperties)
          node[:additionalProperties] == true
        elsif node.key?('additionalProperties')
          node['additionalProperties'] == true
        else
          false
        end
      end

      def symbol_keys?(node)
        node.keys.any? { |key| key.is_a?(Symbol) }
      end

      def clip_description_fields!(node)
        node[:description] = clip_description(node[:description]) if node.key?(:description)
        node['description'] = clip_description(node['description']) if node.key?('description')
      end

      def clip_description(text)
        return text unless text.is_a?(String) && text.length > MAX_DESCRIPTION

        budget = MAX_DESCRIPTION - ELLIPSIS.length
        cut = text[0, budget]
        space = cut.rindex(/[[:space:]]/)
        cut = cut[0, space] if space && space >= (budget * 0.7)
        "#{cut.rstrip}#{ELLIPSIS}"
      end
    end
  end
end
