# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../eval/llm_client'
require_relative '../eval/blind_tester'

class LlmClientTest < Minitest::Test
  IMAGES = [{ 'mime' => 'image/jpeg', 'data' => 'abc' }, { 'mime' => 'image/jpeg', 'data' => 'def' }].freeze

  def openai
    SkMcpEval::OpenAICompatible.new(base_url: 'http://example', model: 'x', api_key: 'k')
  end

  def anthropic
    SkMcpEval::Anthropic.new(base_url: 'http://example', model: 'x', api_key: 'k')
  end

  def test_openai_tool_message_stays_text_only
    message = openai.tool_result_message('1', '{"ok":true}', IMAGES)
    assert_equal 'tool', message[:role]
    assert_equal '1', message[:tool_call_id]
    assert_equal '{"ok":true}', message[:content]
    refute message.key?(:images)
  end

  def test_openai_vision_is_one_user_message_after_tools
    follow = openai.vision_after_tools(IMAGES)
    assert_equal 1, follow.size
    assert_equal 'user', follow.first[:role]
    blocks = follow.first[:content]
    assert_equal 'text', blocks[0][:type]
    assert_equal 3, blocks.size
    assert_equal 'data:image/jpeg;base64,abc', blocks[1][:image_url][:url]
    assert_equal 'data:image/jpeg;base64,def', blocks[2][:image_url][:url]
  end

  def test_openai_vision_is_empty_without_images
    assert_empty openai.vision_after_tools([])
  end

  def test_anthropic_puts_images_on_the_tool_message
    message = anthropic.tool_result_message('1', '{"ok":true}', IMAGES)
    assert_equal 'tool', message[:role]
    assert_equal IMAGES, message[:images]
    assert_empty anthropic.vision_after_tools(IMAGES)
  end

  def look_and_status
    [
      {
        id: '1',
        name: 'model_look',
        result: {
          'content' => [
            { 'type' => 'text', 'text' => '{"ok":true}' },
            { 'type' => 'image', 'mimeType' => 'image/jpeg', 'data' => 'abc' }
          ]
        }
      },
      {
        id: '2',
        name: 'model_status',
        result: { 'content' => [{ 'type' => 'text', 'text' => '{"state":"active"}' }] }
      }
    ]
  end

  def test_openai_keeps_vision_after_all_tool_results
    messages = []
    BlindTester.append_tool_results(messages, openai, look_and_status)
    assert_equal %w[tool tool user], messages.map { |item| item[:role] }
    assert_equal '1', messages[0][:tool_call_id]
    assert_equal '2', messages[1][:tool_call_id]
    refute messages[0].key?(:images)
    refute messages[1].key?(:images)
    assert_equal 1, messages.count { |item| item[:role] == 'user' }
    urls = messages[2][:content].select { |item| item[:type] == 'image_url' }
    assert_equal ['data:image/jpeg;base64,abc'], urls.map { |item| item[:image_url][:url] }
  end

  def test_openai_two_looks_share_one_trailing_vision
    results = [
      {
        id: '1',
        name: 'model_look',
        result: {
          'content' => [
            { 'type' => 'text', 'text' => '{"ok":true}' },
            { 'type' => 'image', 'mimeType' => 'image/jpeg', 'data' => 'abc' }
          ]
        }
      },
      {
        id: '2',
        name: 'model_look',
        result: {
          'content' => [
            { 'type' => 'text', 'text' => '{"ok":true}' },
            { 'type' => 'image', 'mimeType' => 'image/jpeg', 'data' => 'def' }
          ]
        }
      }
    ]
    messages = []
    BlindTester.append_tool_results(messages, openai, results)
    assert_equal %w[tool tool user], messages.map { |item| item[:role] }
    urls = messages[2][:content].select { |item| item[:type] == 'image_url' }
    assert_equal ['data:image/jpeg;base64,abc', 'data:image/jpeg;base64,def'], urls.map { |item| item[:image_url][:url] }
  end

  def test_anthropic_keeps_images_on_the_tool_results
    messages = []
    BlindTester.append_tool_results(messages, anthropic, look_and_status)
    assert_equal %w[tool tool], messages.map { |item| item[:role] }
    assert_equal [{ 'mime' => 'image/jpeg', 'data' => 'abc' }], messages[0][:images]
    assert_empty messages[1][:images]
  end
end
