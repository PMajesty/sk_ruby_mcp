#!/usr/bin/env ruby
# frozen_string_literal: true

# Автономный прогон INTENT-задач через MCP + LLM API. Без Cursor и Claude Code.

require 'fileutils'
require 'json'
require 'optparse'
require_relative 'mcp_client'
require_relative 'llm_client'

module BlindTester
  module_function

  JOBS = %w[massing open_and_windows reshape].freeze

  def run(argv)
    options = defaults
    parser(options).parse!(argv)
    unless options[:model] && options[:base_url]
      warn 'missing --model or --base-url; live LLM jobs are skipped'
      exit 2
    end
    key = ENV[options[:api_key_env].to_s].to_s
    if key.empty? && options[:provider] != 'none'
      warn "missing $#{options[:api_key_env]}; live LLM jobs are skipped"
      exit 2
    end

    @run_id = Time.now.strftime('%Y%m%d-%H%M%S')
    @scratch = File.join(Dir.home, 'sk-mcp-scratch', @run_id)
    FileUtils.mkdir_p(@scratch)
    @out_dir = File.join(File.expand_path(__dir__), 'runs', @run_id)
    FileUtils.mkdir_p(@out_dir)
    @client = SkMcpEval::Client.new
    init = @client.initialize!
    @instructions = init['instructions'].to_s
    @tool_specs = @client.tools
    @llm = build_llm(options, key)
    @model_name = options[:model]
    puts "model=#{@model_name} provider=#{options[:provider]} scratch=#{@scratch}"

    failed = false
    JOBS.each do |job|
      reset_document
      prepare_existing if job != 'massing'
      failed = true unless run_job(job, options)
    end
    exit(failed ? 1 : 0)
  rescue SkMcpEval::Error => error
    warn error.message
    exit 1
  end

  def defaults
    {
      provider: 'openai',
      base_url: ENV['SK_MCP_LLM_BASE_URL'],
      model: ENV['SK_MCP_LLM_MODEL'],
      api_key_env: ENV.fetch('SK_MCP_LLM_KEY_ENV', 'OPENAI_API_KEY'),
      max_turns: 40
    }
  end

  def parser(options)
    OptionParser.new do |opts|
      opts.banner = 'Usage: ruby eval/blind_tester.rb --provider openai|anthropic --base-url URL --model NAME'
      opts.on('--provider NAME', String) { |value| options[:provider] = value }
      opts.on('--base-url URL', String) { |value| options[:base_url] = value }
      opts.on('--model NAME', String) { |value| options[:model] = value }
      opts.on('--api-key-env NAME', String) { |value| options[:api_key_env] = value }
      opts.on('--max-turns N', Integer) { |value| options[:max_turns] = value }
    end
  end

  def build_llm(options, key)
    case options[:provider]
    when 'anthropic'
      SkMcpEval::Anthropic.new(base_url: options[:base_url], model: options[:model], api_key: key)
    else
      SkMcpEval::OpenAICompatible.new(base_url: options[:base_url], model: options[:model], api_key: key)
    end
  end

  def run_job(job, options)
    prompt = File.read(File.join(__dir__, 'jobs', "#{job}.txt")).gsub('JOB_RUN', @run_id).gsub('$HOME', Dir.home)
    messages = [
      { role: 'system', content: @instructions },
      { role: 'user', content: prompt }
    ]
    tools = openai_tools
    transcript = []
    options[:max_turns].times do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reply = @llm.chat(messages, tools)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      record = { role: 'assistant', content: reply[:text], tool_calls: reply[:tool_calls], elapsed_ms: elapsed_ms }
      transcript << record
      break if reply[:tool_calls].nil? || reply[:tool_calls].empty?

      messages << assistant_message(reply)
      results = []
      reply[:tool_calls].each do |call|
        result = @client.call(call[:name], call[:arguments] || {})
        results << { id: call[:id], name: call[:name], arguments: call[:arguments], result: result }
      end
      append_tool_results(messages, @llm, results)
      transcript << { role: 'tool', tool_results: results }
    end
    path = File.join(@out_dir, "#{job}-#{safe(@model_name)}.jsonl")
    File.write(path, transcript.map { |row| JSON.generate(row) }.join("\n") + "\n")
    score = score_job(job, transcript)
    puts "SCORE #{job} #{score.inspect}"
    capable_pass?(score)
  end

  def append_tool_results(messages, llm, results)
    looked = []
    results.each do |item|
      text = item[:result].dig('content', 0, 'text').to_s
      images = look_images(item[:result])
      messages << llm.tool_result_message(item[:id], text, images)
      looked.concat(images)
    end
    llm.vision_after_tools(looked).each { |message| messages << message }
  end

  def look_images(result)
    Array(result['content']).select { |item| item['type'] == 'image' }.map do |item|
      { 'mime' => item['mimeType'], 'data' => item['data'] }
    end
  end

  def assistant_message(reply)
    {
      role: 'assistant',
      content: reply[:text],
      tool_calls: reply[:tool_calls]
    }
  end

  def openai_tools
    @tool_specs.map do |spec|
      {
        type: 'function',
        function: {
          name: spec['name'],
          description: spec['description'],
          parameters: spec['inputSchema'] || { type: 'object', properties: {} }
        }
      }
    end
  end

  def reset_document
    result = @client.call('model_close', 'if_unsaved' => 'discard')
    body = structured(result)
    return if %w[no_document active].include?(body['state'])

    @client.call('model_status')
  rescue SkMcpEval::Error
    nil
  end

  def prepare_existing
    path = File.join(@scratch, 'existing.skp')
    @client.call('model_new')
    @client.call('execute_ruby', 'code' => <<~RUBY)
      model = Sketchup.active_model
      group = model.active_entities.add_group
      face = group.entities.add_face([0, 0, 0], [40, 0, 0], [40, 30, 0], [0, 30, 0])
      face.pushpull(36) if face
      group
    RUBY
    @client.call('model_save', 'mode' => 'save_as', 'path' => path)
    @client.call('model_close')
  end

  def score_job(job, transcript)
    status = structured(@client.call('model_status'))
    calls = transcript.select { |row| row[:tool_results] }.flat_map { |row| row[:tool_results] }
    names = calls.map { |item| item[:name] }
    wrong_tool = 0
    wrong_tool += calls.count { |item| item[:name] == 'execute_ruby' && document_call?(item) }
    opening_new = 0
    names.each_cons(2) { |a, b| opening_new += 1 if a == 'model_new' && b == 'model_new' }
    is_error = calls.count { |item| item[:result]['isError'] }
    polls = calls.count { |item| item[:name] == 'model_status' }
    {
      job_done: job_done?(job, status) ? 1 : 0,
      turns: names.size,
      wrong_tool: wrong_tool + opening_new,
      polls: polls,
      human_questions: 0,
      is_error: is_error,
      unsafe_saves: 0,
      busy_retries: calls.count { |item| structured(item[:result])['error'] == 'busy' },
      path_confusion: 0,
      asked_to_focus_sketchup: transcript.any? { |row| row[:content].to_s.downcase.include?('focus') } ? 1 : 0,
      modelling_faults: 0
    }
  end

  def job_done?(job, status)
    return false unless status['state'] == 'active'

    faces = status.dig('model', 'faces').to_i
    case job
    when 'massing' then faces.positive?
    when 'open_and_windows' then faces.positive?
    when 'reshape' then faces.positive?
    else false
    end
  end

  def document_call?(item)
    code = (item[:arguments] || {})['code'].to_s
    code.match?(/open_file|file_new|save|close/)
  end

  def capable_pass?(score)
    score[:job_done] == 1 && score[:wrong_tool].zero? && score[:unsafe_saves].zero? &&
      score[:human_questions].zero? && score[:asked_to_focus_sketchup].zero?
  end

  def structured(result)
    result['structuredContent'] || begin
      JSON.parse(result.dig('content', 0, 'text').to_s)
    rescue JSON::ParserError
      {}
    end
  end

  def safe(name)
    name.to_s.gsub(/[^\w.-]+/, '_')
  end
end

BlindTester.run(ARGV) if $PROGRAM_NAME == __FILE__
