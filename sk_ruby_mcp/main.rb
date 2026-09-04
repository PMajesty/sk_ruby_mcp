# frozen_string_literal: true

# Точка сборки расширения: загрузка модулей, меню, автозапуск и наблюдатель приложения.
# Только этот файл и runtime/ruby_executor.rb обращаются к API SketchUp напрямую.

%w[
  version clock log settings platform text_trimmer
  runtime/output_capture runtime/ruby_executor
  tools/execute_ruby
  protocol/json_rpc protocol/mcp_handler
  transport/http_connection transport/router transport/loopback_guard transport/mcp_endpoint transport/http_server
].each { |relative_path| Sketchup.require(File.join(__dir__, relative_path)) }

module SkRubyMcp
  MIN_SKETCHUP_MAJOR_VERSION = 22
  LOOPBACK_HOST = '127.0.0.1'
  AUTO_START_DELAY_S = 1.0

  # Композиционный корень: собирает сервер из настроек и управляет его жизненным циклом.
  module App
    INSTRUCTIONS = <<~TEXT.strip
      This server runs inside a live SketchUp session. The only tool, execute_ruby, evaluates Ruby on the
      SketchUp main thread with the full Ruby API. Lengths are inches; use Sketchup.active_model and
      model.active_entities; keep each call short because the SketchUp UI is blocked while code runs;
      never open modal dialogs and never call exit.
    TEXT

    class << self
      attr_reader :server

      def running?
        !@server.nil? && @server.running?
      end

      def start
        return true if running?

        @server = build_server
        @server.start
      end

      def stop
        return false unless running?

        @server.stop
      end

      def toggle
        running? ? stop : start
      end

      def print_status
        port = running? ? @server.port : Settings.get('port')
        Log.sink.puts(<<~TEXT)
          #{Log::PREFIX} #{EXTENSION_NAME} #{VERSION}: #{running? ? 'running' : 'stopped'}
          #{Log::PREFIX} url: http://#{LOOPBACK_HOST}:#{port}/mcp
          #{Log::PREFIX} settings: #{Settings.all}
          #{Log::PREFIX} stats: #{running? ? @server.health : 'n/a'}
          #{Log::PREFIX} Cursor mcp.json: {"mcpServers":{"sketchup":{"url":"http://#{LOOPBACK_HOST}:#{port}/mcp"}}}
          #{Log::PREFIX} change a setting: SkRubyMcp::Settings.set('port', 7891); then restart the server
        TEXT
      end

      private

      def build_server
        router = Transport::Router.new
                                  .add('POST', '/mcp', Transport::McpEndpoint.new(handler: build_handler))
                                  .add('GET', '/health', ->(_request) { Transport::HttpResponse.json(200, @server.health) })
        guard = Transport::LoopbackGuard.new(token: Settings.get('auth_token'))
        Transport::HttpServer.new(
          host: LOOPBACK_HOST,
          port: Settings.get('port'),
          pump_interval: Settings.get('pump_interval'),
          request_handler: ->(request) { guard.check(request) || router.call(request) },
          scheduler: Transport::UiTimerScheduler.new,
          log: Log
        )
      end

      def build_handler
        executor = Runtime::RubyExecutor.new(default_timeout_s: Settings.get('execution_timeout_s'))
        tool = Tools::ExecuteRuby.new(
          executor: executor,
          wrap_in_operation_by_default: Settings.get('wrap_in_operation')
        )
        Protocol::McpHandler.new(
          tools: [tool],
          server_info: { name: SERVER_NAME, version: VERSION },
          instructions: INSTRUCTIONS
        )
      end
    end
  end

  # Останавливает сервер при выходе из SketchUp и при выгрузке расширения.
  class LifecycleObserver < Sketchup::AppObserver
    def onQuit
      App.stop
    end

    def onUnloadExtension(extension_name)
      App.stop if extension_name == EXTENSION_NAME
    end
  end

  unless file_loaded?(__FILE__)
    if Sketchup.version.to_i < MIN_SKETCHUP_MAJOR_VERSION
      Log.warn("SketchUp #{Sketchup.version} is not supported; SketchUp 20#{MIN_SKETCHUP_MAJOR_VERSION} or newer is required")
    else
      menu = UI.menu('Extensions').add_submenu(EXTENSION_NAME)
      toggle_item = menu.add_item('MCP server (start / stop)') { App.toggle }
      menu.set_validation_proc(toggle_item) { App.running? ? MF_CHECKED : MF_UNCHECKED }
      menu.add_item('Show status in Ruby Console') { App.print_status }
      Sketchup.add_observer(LifecycleObserver.new)

      if Settings.get('auto_start')
        UI.start_timer(AUTO_START_DELAY_S, false) do
          begin
            App.start
          rescue StandardError, ScriptError => error
            Log.error("auto-start failed: #{error.class}: #{error.message}")
          end
        end
      end
    end
    file_loaded(__FILE__)
  end
end
