# frozen_string_literal: true

# Точка сборки расширения: загрузка модулей, автозапуск и наблюдатель приложения.
# SketchUp API: этот файл, runtime/ruby_executor.rb, runtime/ensure_active_model.rb,
# runtime/sketchup_document_bridge.rb.

%w[
  version clock log settings settings_ui platform text_trimmer
  runtime/output_capture runtime/ensure_active_model runtime/model_snapshot
  runtime/path_probe runtime/sketchup_document_bridge runtime/skp_header runtime/path_identity runtime/local_path runtime/deferred
  runtime/document_pending runtime/save_policy runtime/document_session runtime/tool_call_gate runtime/ruby_executor
  runtime/viewport_capture runtime/architect_math runtime/scene_geometry runtime/architect_ops
  runtime/facade_math runtime/facade_scene runtime/facade_ops runtime/facade_capture
  tools/tool_support tools/model_tool tools/execute_ruby tools/session_tools tools/model_look
  tools/architect_pack tools/facade_pack
  protocol/json_rpc protocol/mcp_handler
  transport/http_connection transport/router transport/loopback_guard transport/mcp_endpoint transport/http_server
  app
].each { |relative_path| Sketchup.require(File.join(__dir__, relative_path).tr('\\', '/')) }

module SkRubyMcp
  MIN_SKETCHUP_MAJOR_VERSION = 22
  AUTO_START_DELAY_S = 1.0

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
      App.install_plugin_menu

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
