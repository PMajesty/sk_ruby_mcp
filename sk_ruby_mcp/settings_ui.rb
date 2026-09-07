# frozen_string_literal: true

module SkRubyMcp
  # Поля диалога настроек: подписи и виджеты. Хранение и проверка остаются в Settings.
  module SettingsForm
    Field = Struct.new(:key, :prompt, :kind)
    Result = Struct.new(:changed, :restart, :snapshot, :errors, :values, keyword_init: true)

    BOOLEAN_LIST = 'true|false'
    TEXT_LIST = ''
    RUNTIME_KEYS = Settings::RUNTIME_KEYS

    FIELDS = [
      Field.new('port', 'Port (1024-65535)', :integer),
      Field.new('auto_start', 'Start with SketchUp', :boolean),
      Field.new('architect_pack', 'Architect tools', :boolean),
      Field.new('facade_pack', 'Facade tools', :boolean),
      Field.new('auth_token', 'Auth token (empty = off)', :string),
      Field.new('wrap_in_operation', 'Wrap execute_ruby in an undo step', :boolean),
      Field.new('execution_timeout_s', 'execute_ruby timeout in seconds (0.05-3600)', :float),
      Field.new('pump_interval', 'Server tick in seconds (0.01-1.0)', :float)
    ].freeze

    class << self
      def prompts
        FIELDS.map(&:prompt)
      end

      def lists
        FIELDS.map { |field| field.kind == :boolean ? BOOLEAN_LIST : TEXT_LIST }
      end

      def current_values
        FIELDS.map { |field| format_value(field, Settings.get(field.key)) }
      end

      def evaluate(answers)
        unless answers.is_a?(Array) && answers.size == FIELDS.size
          raise ArgumentError, 'answers length must match fields'
        end

        parsed = {}
        errors = []
        FIELDS.each_with_index do |field, index|
          parsed[field.key] = Settings.interpret(field.key, answers[index])
        rescue ArgumentError => error
          errors << error.message
        end
        if errors.any?
          return Result.new(changed: false, restart: false, snapshot: Settings.public_snapshot, errors: errors, values: nil)
        end

        before = Settings.all
        merged = before.merge(parsed)
        Result.new(
          changed: before != merged,
          restart: RUNTIME_KEYS.any? { |key| before[key] != parsed[key] },
          snapshot: Settings.public_snapshot,
          errors: [],
          values: parsed
        )
      end

      def persist(evaluated)
        raise ArgumentError, 'cannot persist invalid settings' if evaluated.errors && !evaluated.errors.empty?
        raise ArgumentError, 'cannot persist without values' if evaluated.values.nil?

        before = Settings.all
        evaluated.values.each { |key, value| Settings.set(key, value) }
        after = Settings.all
        Result.new(
          changed: before != after,
          restart: RUNTIME_KEYS.any? { |key| before[key] != after[key] },
          snapshot: Settings.public_snapshot,
          errors: [],
          values: evaluated.values
        )
      end

      def apply(answers)
        evaluated = evaluate(answers)
        return evaluated if evaluated.errors && !evaluated.errors.empty?

        persist(evaluated)
      end

      private

      def format_value(field, value)
        case field.kind
        when :boolean then value ? 'true' : 'false'
        else value.to_s
        end
      end
    end
  end

  # Нативный диалог SketchUp: UI.inputbox, без HtmlDialog и без HTTP-страницы.
  module SketchupInputBox
    def self.ask(prompts, defaults, lists, title)
      UI.inputbox(prompts, defaults, lists, title)
    end
  end

  # Короткое уведомление после сохранения настроек и старта или остановки сервера.
  module SketchupNotifier
    def self.say(text)
      UI.messagebox(text)
    end

    def self.confirm?(text)
      UI.messagebox(text, MB_YESNO) == IDYES
    end
  end

  # Меню Plugins → SK Ruby MCP: настройки, старт, стоп, статус.
  class PluginMenu
    TITLE = 'SK Ruby MCP settings'
    MENU_HINT = 'Plugins or Extensions → SK Ruby MCP'
    STOP_CONFIRM = 'Stop the MCP server? Connected clients will drop.'
    RESTART_CONFIRM = 'These settings restart the MCP server. Connected clients will drop. Continue?'

    def initialize(ui:, app:, dialog:, notifier:)
      @ui = ui
      @app = app
      @dialog = dialog
      @notifier = notifier
      @installed = false
    end

    def installed?
      @installed
    end

    def install
      return false if @installed

      menu = plugins_menu.add_submenu(EXTENSION_NAME)
      menu.add_item('Settings...') { open_settings }
      menu.add_separator
      menu.add_item('Start server') { start_server }
      menu.add_item('Stop server') { stop_server }
      menu.add_item('Status') { show_status }
      @installed = true
      true
    end

    def open_settings(defaults = SettingsForm.current_values)
      answers = @dialog.ask(SettingsForm.prompts, defaults, SettingsForm.lists, TITLE)
      return :cancelled if answers == false || answers.nil?

      unless answers.is_a?(Array) && answers.size == SettingsForm::FIELDS.size
        @notifier.say('Settings were not saved.')
        return :invalid
      end

      result = SettingsForm.evaluate(answers)
      if result.errors && !result.errors.empty?
        @notifier.say("Settings were not saved.\n#{result.errors.join("\n")}")
        return open_settings(answers)
      end

      if result.restart && @app.running?
        unless @notifier.confirm?(RESTART_CONFIRM)
          @notifier.say('Settings were not saved.')
          return :cancelled
        end
      end

      result = SettingsForm.persist(result)
      apply_runtime(result)
    end

    def start_server
      if @app.running?
        @notifier.say("MCP server is already running at #{listen_url}.")
        return :already_running
      end

      if @app.start
        @notifier.say("MCP server started at #{listen_url}.")
        :started
      else
        @app.print_status
        @notifier.say(
          "MCP server could not start on #{listen_url}. The port may already be in use. Check the Ruby Console."
        )
        :start_failed
      end
    end

    def stop_server
      unless @app.running?
        @notifier.say('MCP server is not running.')
        return :not_running
      end
      return :cancelled unless @notifier.confirm?(STOP_CONFIRM)

      @app.stop
      @notifier.say('MCP server stopped.')
      :stopped
    end

    private

    def plugins_menu
      @ui.menu('Plugins') || @ui.menu('Extensions')
    end

    def listen_url
      @app.listen_url
    end

    def show_status
      if @app.running?
        @notifier.say("MCP server is running at #{listen_url}.")
      else
        @notifier.say(
          "MCP server is stopped. Saved port: #{Settings.get('port')}. Use #{MENU_HINT} → Start server."
        )
      end
    end

    def apply_runtime(result)
      if result.restart && @app.running?
        @app.stop
        unless @app.start
          @notifier.say(
            "The MCP server could not restart and is stopped. Check the port, then use #{MENU_HINT} → Start server.\n#{saved_snapshot(result)}"
          )
          return :restart_failed
        end
        @notifier.say("MCP server restarted at #{listen_url}.\n#{saved_snapshot(result)}")
        return :restarted
      end

      if result.restart && !@app.running?
        @notifier.say("Use #{MENU_HINT} → Start server to apply these settings.\n#{saved_snapshot(result)}")
        return :saved
      end

      if result.changed
        @notifier.say(saved_snapshot(result))
        :saved
      else
        @notifier.say('No settings changed.')
        :unchanged
      end
    end

    def saved_snapshot(result)
      rows = result.snapshot.map { |key, value| "#{key}: #{value}" }.join("\n")
      "Settings saved.\n#{rows}"
    end
  end
end
