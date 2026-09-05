# frozen_string_literal: true

# Точка сборки расширения: загрузка модулей, автозапуск и наблюдатель приложения.
# SketchUp API: этот файл, runtime/ruby_executor.rb, runtime/ensure_active_model.rb,
# runtime/sketchup_document_bridge.rb.

%w[
  version clock log settings platform text_trimmer
  runtime/output_capture runtime/ensure_active_model runtime/model_snapshot
  runtime/sketchup_document_bridge runtime/skp_header runtime/path_identity runtime/deferred
  runtime/document_pending runtime/save_policy runtime/document_session runtime/tool_call_gate runtime/ruby_executor
  tools/tool_support tools/execute_ruby tools/session_tools
  protocol/json_rpc protocol/mcp_handler
  transport/http_connection transport/router transport/loopback_guard transport/mcp_endpoint transport/http_server
].each { |relative_path| Sketchup.require(File.join(__dir__, relative_path)) }

module SkRubyMcp
  MIN_SKETCHUP_MAJOR_VERSION = 22
  LOOPBACK_HOST = '127.0.0.1'
  LOOPBACK_HOSTS = ['127.0.0.1', '::1'].freeze
  AUTO_START_DELAY_S = 1.0

  # Композиционный корень: собирает сервер из настроек и управляет его жизненным циклом.
  module App
    INSTRUCTIONS = <<~TEXT.strip
      SketchUp MCP on this computer. One focused document at a time.
      model_status: what is focused plus a model summary; call first and after any state opening (wait_s=15). model_open: open or switch to an existing .skp. model_new: blank document. model_save: mode in_place, save_as or copy. model_close: close. model_revert: discard unsaved changes and reload the last save, with no confirmation. execute_ruby: all modelling.
      Unsaved changes on open, new or close need if_unsaved=save (files this session opened or saved) or if_unsaved=discard. Nothing is saved or discarded by default.
      Replies are JSON: path is the real path on disk (null for Untitled); state is active, no_document, opening or failed; a failure has message, next (what to call), retry and instead. temporary true means call model_save with mode save_as and a path before treating the file as finished.
      No reply or connection refused means SketchUp is closed or the server is stopped: ask the architect to start SketchUp, then call model_status. Do not assume the last file is still focused.
      Lengths are inches unless written like 10.m. Never open dialogs. Never call exit.
    TEXT

    class << self
      attr_reader :server, :document_session

      def running?
        !@server.nil? && @server.running?
      end

      def start
        return true if running?

        @server = build_server
        @runtime_settings = Settings.public_snapshot
        @server.start
      end

      def stop
        return false unless running?

        stopped = @server.stop
        @document_session = nil
        @runtime_settings = nil
        stopped
      end

      def ensure_pump
        return false unless running?

        @server.restart_pump
      end

      def print_status
        if defined?(SKETCHUP_CONSOLE) && SKETCHUP_CONSOLE.respond_to?(:show)
          SKETCHUP_CONSOLE.show
        end
        port = running? ? @server.port : Settings.get('port')
        applied = running? ? @runtime_settings : Settings.public_snapshot
        stale = running? && @runtime_settings && @runtime_settings != Settings.public_snapshot
        Log.emit(<<~TEXT)
          #{Log::PREFIX} #{EXTENSION_NAME} #{VERSION}: #{running? ? 'running' : 'stopped'}
          #{Log::PREFIX} url: http://#{LOOPBACK_HOST}:#{port}/mcp
          #{Log::PREFIX} settings: #{applied}
          #{Log::PREFIX} stats: #{running? ? @server.health : 'n/a'}
        TEXT
        if stale
          Log.emit("#{Log::PREFIX} settings file changed; stop and start the MCP server to apply")
        end
      end

      def note_external_document_change
        @document_session.note_external_switch if @document_session
        ensure_pump
      end

      private

      def build_server
        gate = Runtime::ToolCallGate.new
        attach = Runtime::SketchupAttachBridge.new
        executor = Runtime::RubyExecutor.new(
          host: Runtime::SketchupHost.new(attach: attach),
          default_timeout_s: Settings.get('execution_timeout_s')
        )
        session = Runtime::DocumentSession.new(
          bridge: Runtime::SketchupDocumentBridge.new(attach: attach),
          locals_cleaner: -> { executor.reset_document_scope }
        )
        @document_session = session
        drop_parked = nil
        handler = build_handler(gate, session, executor)
        handler.on_cancel = ->(request_id) { drop_parked && drop_parked.call(request_id) }
        router = Transport::Router.new
                                  .add('POST', '/mcp', Transport::McpEndpoint.new(handler: handler))
                                  .add('GET', '/health', ->(_request) { Transport::HttpResponse.json(200, @server.health) })
        guard = Transport::LoopbackGuard.new(token: Settings.get('auth_token'))
        server = Transport::HttpServer.new(
          host: LOOPBACK_HOST,
          hosts: LOOPBACK_HOSTS,
          port: Settings.get('port'),
          pump_interval: Settings.get('pump_interval'),
          request_handler: ->(request) { guard.check(request) || router.call(request) },
          scheduler: Transport::UiTimerScheduler.new,
          log: Log,
          on_tick_begin: lambda do
            gate.begin_tick
            session.begin_tick
          end
        )
        drop_parked = ->(request_id) { server.drop_parked(request_id) }
        server
      end

      def build_handler(call_gate, session, executor)
        tools = [
          Tools::ModelStatus.new(session: session),
          Tools::ModelOpen.new(session: session),
          Tools::ModelNew.new(session: session),
          Tools::ModelSave.new(session: session),
          Tools::ModelClose.new(session: session),
          Tools::ModelRevert.new(session: session),
          Tools::ExecuteRuby.new(
            executor: executor,
            session: session,
            wrap_in_operation_by_default: Settings.get('wrap_in_operation')
          )
        ]
        Protocol::McpHandler.new(
          tools: tools,
          server_info: { name: SERVER_NAME, version: VERSION },
          instructions: INSTRUCTIONS,
          call_gate: call_gate
        )
      end
    end
  end

  # Останавливает сервер при выходе и поднимает помпу, когда появляется документ.
  class LifecycleObserver < Sketchup::AppObserver
    def expectsStartupModelNotifications
      true
    end

    def onQuit
      App.stop
    end

    def onUnloadExtension(extension_name)
      App.stop if extension_name == EXTENSION_NAME
    end

    def onExtensionsLoaded
      return unless Settings.get('auto_start')

      App.running? ? App.ensure_pump : App.start
    rescue StandardError, ScriptError => error
      Log.error("pump restart on extensions loaded failed: #{error.class}: #{error.message}")
    end

    def onNewModel(_model)
      App.note_external_document_change
    rescue StandardError, ScriptError => error
      Log.error("pump restart on new model failed: #{error.class}: #{error.message}")
    end

    def onOpenModel(_model)
      App.note_external_document_change
    rescue StandardError, ScriptError => error
      Log.error("pump restart on open model failed: #{error.class}: #{error.message}")
    end

    def onActivateModel(_model)
      App.note_external_document_change
    rescue StandardError, ScriptError => error
      Log.error("pump restart on activate model failed: #{error.class}: #{error.message}")
    end
  end

  unless file_loaded?(__FILE__)
    if Sketchup.version.to_i < MIN_SKETCHUP_MAJOR_VERSION
      Log.warn("SketchUp #{Sketchup.version} is not supported; SketchUp 20#{MIN_SKETCHUP_MAJOR_VERSION} or newer is required")
    else
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
