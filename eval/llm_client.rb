# frozen_string_literal: true

# Два адаптера LLM за одним интерфейсом chat(messages, tools).

require 'json'
require 'net/http'
require 'uri'

module SkMcpEval
  class LlmError < StandardError; end

  class OpenAICompatible
    def initialize(base_url:, model:, api_key:, timeout: 120)
      @base_url = base_url.to_s.sub(%r{/+\z}, '')
      @model = model
      @api_key = api_key
      @timeout = timeout
    end

    def chat(messages, tools)
      payload = { model: @model, messages: messages }
      payload[:tools] = tools unless tools.nil? || tools.empty?
      body = post("#{@base_url}/chat/completions", payload, extra: { 'Authorization' => "Bearer #{@api_key}" })
      choice = body.fetch('choices').fetch(0).fetch('message')
      {
        text: choice['content'].to_s,
        tool_calls: Array(choice['tool_calls']).map { |item| openai_tool_call(item) }
      }
    end

    def tool_result_message(id, text, _images)
      { role: 'tool', tool_call_id: id, content: text }
    end

    def vision_after_tools(images)
      return [] if images.nil? || images.empty?

      vision = [{ type: 'text', text: 'Viewport from model_look.' }]
      images.each do |image|
        vision << { type: 'image_url', image_url: { url: "data:#{image['mime']};base64,#{image['data']}" } }
      end
      [{ role: 'user', content: vision }]
    end

    private

    def openai_tool_call(item)
      function = item['function'] || {}
      arguments = function['arguments']
      parsed = arguments.is_a?(String) && !arguments.empty? ? JSON.parse(arguments) : (arguments || {})
      { id: item['id'], name: function['name'], arguments: parsed }
    end

    def post(url, payload, extra: {})
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      extra.each { |name, value| request[name] = value }
      request.body = JSON.generate(payload)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: @timeout, open_timeout: 10) do |http|
        http.request(request)
      end
      raise LlmError, "HTTP #{response.code} #{response.body}" unless response.code.to_i == 200

      JSON.parse(response.body)
    end
  end

  class Anthropic
    def initialize(base_url:, model:, api_key:, timeout: 120)
      @base_url = base_url.to_s.sub(%r{/+\z}, '')
      @model = model
      @api_key = api_key
      @timeout = timeout
    end

    def chat(messages, tools)
      system = messages.select { |item| item[:role] == 'system' || item['role'] == 'system' }.map { |item| item[:content] || item['content'] }.join("\n")
      converted = messages.reject { |item| (item[:role] || item['role']) == 'system' }.map { |item| anthropic_message(item) }
      payload = { model: @model, max_tokens: 4096, messages: converted }
      payload[:system] = system unless system.empty?
      payload[:tools] = tools unless tools.nil? || tools.empty?
      body = post("#{@base_url}/v1/messages", payload)
      blocks = body.fetch('content')
      text = blocks.select { |item| item['type'] == 'text' }.map { |item| item['text'] }.join
      calls = blocks.select { |item| item['type'] == 'tool_use' }.map do |item|
        { id: item['id'], name: item['name'], arguments: item['input'] || {} }
      end
      { text: text, tool_calls: calls }
    end

    def tool_result_message(id, text, images)
      { role: 'tool', tool_call_id: id, content: text, images: images }
    end

    def vision_after_tools(_images)
      []
    end

    private

    def anthropic_message(item)
      role = item[:role] || item['role']
      if role == 'tool'
        {
          'role' => 'user',
          'content' => [{
            'type' => 'tool_result',
            'tool_use_id' => item[:tool_call_id] || item['tool_call_id'],
            'content' => anthropic_tool_content(item)
          }]
        }
      elsif role == 'assistant' && item[:tool_calls]
        content = []
        text = item[:content] || item['content']
        content << { 'type' => 'text', 'text' => text } unless text.to_s.empty?
        Array(item[:tool_calls]).each do |call|
          content << { 'type' => 'tool_use', 'id' => call[:id], 'name' => call[:name], 'input' => call[:arguments] }
        end
        { 'role' => 'assistant', 'content' => content }
      else
        { 'role' => role, 'content' => item[:content] || item['content'] }
      end
    end

    def anthropic_tool_content(item)
      text = item[:content] || item['content']
      images = item[:images] || item['images'] || []
      return text if images.empty?

      blocks = []
      blocks << { 'type' => 'text', 'text' => text } unless text.to_s.empty?
      images.each do |image|
        blocks << {
          'type' => 'image',
          'source' => {
            'type' => 'base64',
            'media_type' => image['mime'],
            'data' => image[:data] || image['data']
          }
        }
      end
      blocks
    end

    def post(url, payload)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = @api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = JSON.generate(payload)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: @timeout, open_timeout: 10) do |http|
        http.request(request)
      end
      raise LlmError, "HTTP #{response.code} #{response.body}" unless response.code.to_i == 200

      JSON.parse(response.body)
    end
  end
end
