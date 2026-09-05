#!/usr/bin/env ruby
# frozen_string_literal: true

# Двадцать операций документа против живого SketchUp. Повтор: ruby eval/soak.rb

require 'fileutils'
require 'json'
require_relative 'mcp_client'

module Soak
  module_function

  EXPECTED_ERRORS = [].freeze
  EXPECTED_CHANGED = {
    'model_new' => 'created',
    'save_a' => 'saved_as',
    'new_save' => 'created',
    'save_b' => 'saved_as',
    'open_a' => 'opened',
    'copy_a' => 'copied',
    'close' => 'closed',
    'open_b' => 'opened',
    'revert' => 'reverted',
    'open_a_discard' => 'opened',
    'close_discard' => 'closed',
    'new_blank' => 'created',
    'close_blank' => 'closed',
    'open_copy' => 'opened',
    'save_in_place' => 'saved',
    'revert_copy' => 'reverted',
    'new_last' => 'created',
    'close_last' => 'closed'
  }.freeze

  def run
    run_id = Time.now.strftime('%Y%m%d-%H%M%S')
    scratch = File.join(Dir.home, 'sk-mcp-scratch', run_id)
    FileUtils.mkdir_p(scratch)
    @client = SkMcpEval::Client.new
    @client.initialize!
    @rows = []
    @failed = false
    crash_before = diagnostic_reports

    a = File.join(scratch, 'a.skp')
    b = File.join(scratch, 'b.skp')
    a_copy = File.join(scratch, 'a-copy.skp')

    step('model_new', 'model_new')
    wait_until_active
    step('draw_box', 'execute_ruby', code: BOX)
    step('save_a', 'model_save', mode: 'save_as', path: a)
    step('new_save', 'model_new', if_unsaved: 'save')
    step('save_b', 'model_save', mode: 'save_as', path: b)
    step('open_a', 'model_open', path: a)
    step('copy_a', 'model_save', mode: 'copy', path: a_copy)
    step('close', 'model_close')
    step('open_b', 'model_open', path: b)
    step('draw_again', 'execute_ruby', code: BOX)
    step('revert', 'model_revert')
    step('open_a_discard', 'model_open', path: a, if_unsaved: 'discard')
    step('close_discard', 'model_close', if_unsaved: 'discard')
    step('new_blank', 'model_new')
    step('close_blank', 'model_close')
    step('open_copy', 'model_open', path: a_copy)
    step('save_in_place', 'model_save', mode: 'in_place')
    step('revert_copy', 'model_revert')
    step('new_last', 'model_new')
    step('close_last', 'model_close')

    if diagnostic_reports.size > crash_before.size
      puts 'FAIL SketchUp crash report appeared'
      @failed = true
    end

    print_table
    exit(@failed ? 1 : 0)
  rescue SkMcpEval::Error => error
    puts "FAIL #{error.message}"
    exit 1
  end

  BOX = <<~RUBY
    model = Sketchup.active_model
    ents = model.active_entities
    group = ents.add_group
    face = group.entities.add_face([0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0])
    face.pushpull(10) if face
    group
  RUBY

  def step(label, name, arguments = {})
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = @client.call(name, arguments)
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    body = structured(result)
    if body['state'] == 'opening' && !result['isError']
      result = wait_until_active
      body = structured(result)
    end
    unexpected = result['isError'] && !EXPECTED_ERRORS.include?(label)
    expected_changed = EXPECTED_CHANGED[label]
    wrong_changed = expected_changed && body['changed'] != expected_changed
    @failed = true if unexpected || wrong_changed
    @rows << {
      label: label,
      elapsed_ms: elapsed_ms,
      state: body['state'],
      changed: body['changed'],
      error: unexpected ? body['error'] : nil
    }
    detail = if unexpected
               " error=#{body['error']}"
             elsif wrong_changed
               " expected_changed=#{expected_changed}"
             else
               ''
             end
    puts format(
      '%s %s %sms state=%s changed=%s%s',
      (unexpected || wrong_changed) ? 'FAIL' : 'PASS',
      label,
      elapsed_ms,
      body['state'],
      body['changed'],
      detail
    )
  end

  def wait_until_active
    @client.call('model_status', wait_s: 15)
  end

  def structured(result)
    result['structuredContent'] || begin
      text = result.dig('content', 0, 'text').to_s
      text.empty? ? {} : JSON.parse(text)
    rescue JSON::ParserError
      {}
    end
  end

  def print_table
    puts '--- soak ---'
    @rows.each do |row|
      puts "#{row[:label]}\t#{row[:elapsed_ms]}\t#{row[:state]}\t#{row[:changed]}"
    end
  end

  def diagnostic_reports
    Dir.glob(File.expand_path('~/Library/Logs/DiagnosticReports/SketchUp*'))
  end
end

Soak.run if $PROGRAM_NAME == __FILE__
