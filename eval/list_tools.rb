#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'mcp_client'

client = SkMcpEval::Client.new
init = client.initialize!
puts "version=#{init.dig('serverInfo', 'version')}"
puts client.tools.map { |tool| tool['name'] }.join(',')
puts init['instructions']
