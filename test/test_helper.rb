# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'socket'
require 'stringio'

SOURCE_ROOT = File.expand_path('../sk_ruby_mcp', __dir__)
%w[
  version clock log settings platform text_trimmer
  runtime/output_capture runtime/ruby_executor
  tools/execute_ruby
  protocol/json_rpc protocol/mcp_handler
  transport/http_connection transport/router transport/loopback_guard transport/mcp_endpoint transport/http_server
].each { |relative_path| require File.join(SOURCE_ROOT, relative_path) }

SkRubyMcp::Log.sink = StringIO.new

# Заглушки вместо SketchUp и таймера UI: тесты проверяют поведение ядра без приложения.
module TestSupport
  class FakeView
    attr_reader :invalidations

    def initialize
      @invalidations = 0
    end

    def invalidate
      @invalidations += 1
    end
  end

  class FakeModel
    attr_reader :events, :active_view

    def initialize
      @events = []
      @active_view = FakeView.new
    end

    def valid?
      true
    end

    def start_operation(name, disable_ui = false, *_rest)
      @events << [:start, name, disable_ui]
      true
    end

    def commit_operation
      @events << [:commit]
      true
    end

    def abort_operation
      @events << [:abort]
      true
    end
  end

  class FakeHost
    attr_accessor :model

    def initialize(model = FakeModel.new)
      @model = model
    end

    def active_model
      @model
    end

    def invalidate_view(model)
      model.active_view.invalidate
    end
  end

  class ManualScheduler
    attr_reader :interval, :cancelled

    def every(interval_s, &block)
      @interval = interval_s
      @block = block
      @cancelled = false
    end

    def cancel
      @cancelled = true
      @block = nil
    end

    def tick!
      @block&.call
    end
  end

  class RecordingLog
    attr_reader :messages

    def initialize
      @messages = []
    end

    %i[debug info warn error].each do |level|
      define_method(level) { |message| @messages << [level, message] }
    end
  end

  class SpyExecutor
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def execute(code, operation_name:, wrap_in_operation:, timeout_s: nil)
      @calls << [code, operation_name, wrap_in_operation, timeout_s]
      @result
    end

    def model_present?
      true
    end
  end

  def self.execution_result(**overrides)
    defaults = {
      ok: true, return_value: '2', stdout: '', stderr: '', error: nil,
      elapsed_ms: 1.5, truncated: false, model_present: true
    }
    SkRubyMcp::Runtime::ExecutionResult.new(**defaults.merge(overrides))
  end

  def self.free_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  def self.http_request(method, path, body: nil, headers: {})
    lines = ["#{method} #{path} HTTP/1.1", 'Host: 127.0.0.1']
    headers.each { |name, value| lines << "#{name}: #{value}" }
    lines << "Content-Length: #{body.bytesize}" if body
    "#{lines.join("\r\n")}\r\n\r\n#{body}"
  end

  def self.parse_response(raw)
    head, body = raw.split("\r\n\r\n", 2)
    status_line, *header_lines = head.split("\r\n")
    headers = header_lines.each_with_object({}) do |line, collected|
      name, value = line.split(': ', 2)
      collected[name.downcase] = value
    end
    [status_line.split(' ')[1].to_i, headers, body.to_s]
  end

  def self.json_rpc(method, params = nil, id: 1)
    message = { jsonrpc: '2.0', id: id, method: method }
    message[:params] = params if params
    JSON.generate(message)
  end
end
