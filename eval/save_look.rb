#!/usr/bin/env ruby
# frozen_string_literal: true

# Живой вызов model_look: JSON в stdout, JPEG в файл (второй аргумент).
# ruby eval/save_look.rb [view] [out.jpg]

require 'base64'
require 'fileutils'
require 'json'
require_relative 'mcp_client'

view = ARGV[0] || 'iso'
out = ARGV[1] || File.join(Dir.home, 'sk-mcp-scratch', "look-#{view}.jpg")
client = SkMcpEval::Client.new
client.initialize!
result = client.call('model_look', 'view' => view)
image = Array(result['content']).find { |item| item['type'] == 'image' }
FileUtils.mkdir_p(File.dirname(out))
if image && image['data']
  File.binwrite(out, Base64.decode64(image['data']))
  result = result.merge('saved' => File.expand_path(out))
end
puts JSON.pretty_generate(result['structuredContent'] || result)
puts "saved=#{File.expand_path(out)}" if image
exit(result['isError'] ? 1 : 0)
