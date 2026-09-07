# frozen_string_literal: true

module SkRubyMcp
  LOOPBACK_HOST = '127.0.0.1'
  LOOPBACK_HOSTS = ['127.0.0.1', '::1'].freeze

  # Композиционный корень: собирает сервер из настроек и управляет его жизненным циклом.
  module App
    INSTRUCTIONS = <<~TEXT.strip
      SketchUp MCP on this computer. One focused document at a time.
      model_status: what is focused plus a model summary; call first and after any state opening (wait_s=15). model_look: a JPEG of the viewport when you need to see the model; do not poll it. model_open: open or switch to an existing .skp. model_new: blank document. model_save: mode in_place, save_as or copy. model_close: close. model_revert: discard unsaved changes and reload the last save, with no confirmation. execute_ruby: all modelling.
      Unsaved changes on open, new or close need if_unsaved=save (files this session opened or saved) or if_unsaved=discard. Nothing is saved or discarded by default.
      Replies are JSON: path is the real path on disk (null for Untitled); state is active, no_document, opening or failed; a failure has message, next (what to call), retry and instead. temporary true means call model_save with mode save_as and a path before treating the file as finished.
      No reply or connection refused means SketchUp is closed, the MCP server is stopped, or the client is using the wrong port. If SketchUp is open, ask the architect to use Plugins or Extensions → SK Ruby MCP → Start server if needed, then Status only for a listening URL, then point this MCP client at that URL, then call model_status. Status while stopped is not a URL. A wrong port is not a stopped server. If SketchUp is closed, ask the architect to start SketchUp, then call model_status. Do not assume the last file is still focused.
      Lengths are inches unless written like 10.m. Never open dialogs. Never call exit.
    TEXT
    PACK_NOTE = 'Named modelling helpers may also be listed; use them when they match the job. execute_ruby remains for everything else.'

    class << self
      attr_reader :server, :document_session

      def listen_url
        "http://#{LOOPBACK_HOST}:#{listen_port}/mcp"
      end

      def listen_port
        running? ? @server.port : Settings.get('port')
      end

      def running?
        !@server.nil? && @server.running?
      end

      def start
        return true if running?

        @server = build_server
        @runtime_settings = Settings.all
        return true if @server.start

        abandon_failed_start
        false
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
        applied = running? ? Settings.public_snapshot(@runtime_settings) : Settings.public_snapshot
        stale = running? && @runtime_settings && Settings.runtime_slice(@runtime_settings) != Settings.runtime_slice
        text = if running?
                 <<~TEXT
                   #{Log::PREFIX} #{EXTENSION_NAME} #{VERSION}: running
                   #{Log::PREFIX} url: #{listen_url}
                   #{Log::PREFIX} settings: #{applied}
                   #{Log::PREFIX} stats: #{@server.health}
                 TEXT
               else
                 <<~TEXT
                   #{Log::PREFIX} #{EXTENSION_NAME} #{VERSION}: stopped
                   #{Log::PREFIX} not listening. Saved port: #{Settings.get('port')}. Use Plugins or Extensions → SK Ruby MCP → Start server.
                   #{Log::PREFIX} settings: #{applied}
                   #{Log::PREFIX} stats: n/a
                 TEXT
               end
        text += "#{Log::PREFIX} settings changed; stop and start the MCP server to apply\n" if stale
        Log.emit(text)
        text
      end

      def note_external_document_change
        @document_session.note_external_switch if @document_session
        ensure_pump
      end

      def install_plugin_menu
        return unless defined?(UI) && UI.respond_to?(:menu)

        @plugin_menu ||= PluginMenu.new(
          ui: UI,
          app: self,
          dialog: SketchupInputBox,
          notifier: SketchupNotifier
        )
        @plugin_menu.install
      end

      private

      def abandon_failed_start
        @server = nil
        @document_session = nil
        @runtime_settings = nil
      end

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
        handler = build_handler(gate, session, executor, attach)
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

      def build_handler(call_gate, session, executor, attach)
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
          ),
          Tools::ModelLook.new(
            session: session,
            capturer: Runtime::ViewportCapture.new(model_provider: -> { attach.current_model })
          )
        ]
        tools.concat(Tools::ArchitectPack.instances(session: session, attach: attach)) if Settings.get('architect_pack')
        tools.concat(Tools::FacadePack.instances(session: session, attach: attach)) if Settings.get('facade_pack')
        packs_on = Settings.get('architect_pack') || Settings.get('facade_pack')
        instructions = packs_on ? "#{INSTRUCTIONS}\n#{PACK_NOTE}" : INSTRUCTIONS
        Protocol::McpHandler.new(
          tools: tools,
          server_info: { name: SERVER_NAME, version: VERSION },
          instructions: instructions,
          call_gate: call_gate
        )
      end
    end
  end
end
