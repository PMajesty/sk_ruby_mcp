# frozen_string_literal: true

require_relative 'test_helper'

class SettingsFormTest < Minitest::Test
  Settings = SkRubyMcp::Settings
  Form = SkRubyMcp::SettingsForm

  def setup
    @store = {}
    @previous = TestSupport.replace_sketchup(TestSupport.sketchup_defaults_store(@store))
  end

  def teardown
    TestSupport.restore_sketchup(@previous)
  end

  def test_form_covers_every_setting_key
    form_keys = Form::FIELDS.map(&:key)
    assert_equal Settings::DEFAULTS.keys.sort, form_keys.sort
  end

  def test_current_values_match_defaults_as_dialog_strings
    expected = Form::FIELDS.map do |field|
      value = Settings::DEFAULTS[field.key]
      field.kind == :boolean ? (value ? 'true' : 'false') : value.to_s
    end
    assert_equal expected, Form.current_values
  end

  def test_boolean_fields_use_true_false_lists
    Form::FIELDS.each_with_index do |field, index|
      if field.kind == :boolean
        assert_equal 'true|false', Form.lists[index], field.key
      else
        assert_equal '', Form.lists[index], field.key
      end
    end
  end

  def test_apply_writes_values_and_marks_runtime_restart
    answers = Form.current_values
    port_index = Form::FIELDS.index { |field| field.key == 'port' }
    answers[port_index] = '7892'
    result = Form.apply(answers)
    assert_equal true, result.changed
    assert_equal true, result.restart
    assert_equal 7892, Settings.get('port')
  end

  def test_apply_auto_start_alone_does_not_require_restart
    answers = Form.current_values
    index = Form::FIELDS.index { |field| field.key == 'auto_start' }
    answers[index] = 'false'
    result = Form.apply(answers)
    assert_equal true, result.changed
    assert_equal false, result.restart
    assert_equal false, Settings.get('auto_start')
  end

  def test_apply_pack_toggle_requires_restart
    answers = Form.current_values
    answers[Form::FIELDS.index { |field| field.key == 'architect_pack' }] = 'false'
    result = Form.apply(answers)
    assert_equal true, result.changed
    assert_equal true, result.restart
    assert_equal false, Settings.get('architect_pack')
  end

  def test_apply_same_values_is_unchanged
    result = Form.apply(Form.current_values)
    assert_equal false, result.changed
    assert_equal false, result.restart
    assert_equal [], result.errors
  end

  def test_apply_rejects_invalid_port_without_writing
    answers = Form.current_values
    answers[Form::FIELDS.index { |field| field.key == 'port' }] = '80'
    result = Form.apply(answers)
    refute_empty result.errors
    assert_equal false, result.changed
    assert_equal 7891, Settings.get('port')
  end

  def test_prompts_include_numeric_ranges
    prompts = Form.prompts.join(' ')
    assert_includes prompts, '1024-65535'
    assert_includes prompts, '0.05-3600'
    assert_includes prompts, '0.01-1.0'
  end

  def test_apply_rejects_wrong_length
    assert_raises(ArgumentError) { Form.apply(['7891']) }
    assert_raises(ArgumentError) { Form.apply(nil) }
  end

  def test_apply_redacts_token_in_snapshot
    answers = Form.current_values
    index = Form::FIELDS.index { |field| field.key == 'auth_token' }
    answers[index] = 'secret-token'
    result = Form.apply(answers)
    assert_equal '(set)', result.snapshot['auth_token']
    refute_includes result.snapshot.values.map(&:to_s), 'secret-token'
  end
end

class PluginMenuTest < Minitest::Test
  Form = SkRubyMcp::SettingsForm

  class RecordingMenu
    attr_reader :submenu_name, :items

    def initialize
      @items = []
    end

    def add_submenu(name)
      @submenu_name = name
      self
    end

    def add_item(name, &block)
      @items << [name, block]
    end

    def add_separator
      @items << :separator
    end
  end

  class RecordingUI
    attr_reader :root_name, :root_menu

    def initialize
      @root_menu = RecordingMenu.new
    end

    def menu(name)
      @root_name = name
      @root_menu
    end
  end

  class FakeApp
    BOUND_URL = 'http://127.0.0.1:7900/mcp'

    attr_accessor :running, :start_result
    attr_reader :starts, :stops, :status_calls

    def initialize(running: false, start_result: true)
      @running = running
      @start_result = start_result
      @starts = 0
      @stops = 0
      @status_calls = 0
    end

    def running?
      @running
    end

    def start
      @starts += 1
      @running = @start_result
      @start_result
    end

    def stop
      @stops += 1
      @running = false
      true
    end

    def print_status
      @status_calls += 1
      'status'
    end

    def listen_url
      return BOUND_URL if @running

      "http://#{SkRubyMcp::LOOPBACK_HOST}:#{SkRubyMcp::Settings.get('port')}/mcp"
    end
  end

  class FakeDialog
    attr_reader :asks

    def initialize(answers)
      @replies = [answers]
      @asks = 0
    end

    def answers=(value)
      @replies = [value]
    end

    def replies=(list)
      @replies = list.dup
    end

    def ask(*_args)
      @asks += 1
      @replies.shift
    end
  end

  class FakeNotifier
    attr_reader :messages, :confirms
    attr_accessor :confirm

    def initialize
      @messages = []
      @confirms = []
      @confirm = true
    end

    def say(text)
      @messages << text
    end

    def confirm?(text)
      @confirms << text
      @confirm
    end
  end

  def setup
    @store = {}
    @previous = TestSupport.replace_sketchup(TestSupport.sketchup_defaults_store(@store))
    @ui = RecordingUI.new
    @app = FakeApp.new
    @dialog = FakeDialog.new(false)
    @notifier = FakeNotifier.new
    @menu = SkRubyMcp::PluginMenu.new(ui: @ui, app: @app, dialog: @dialog, notifier: @notifier)
  end

  def teardown
    TestSupport.restore_sketchup(@previous)
  end

  def test_install_adds_settings_and_server_items_once
    assert @menu.install
    refute @menu.install
    assert_equal 'Plugins', @ui.root_name
    assert_equal SkRubyMcp::EXTENSION_NAME, @ui.root_menu.submenu_name
    names = @ui.root_menu.items.map { |item| item == :separator ? :separator : item[0] }
    assert_equal ['Settings...', :separator, 'Start server', 'Stop server', 'Status'], names
  end

  def test_menu_start_stop_status_call_the_app
    @menu.install
    items = @ui.root_menu.items.each_with_object({}) do |item, by_name|
      by_name[item[0]] = item[1] if item.is_a?(Array)
    end
    items['Start server'].call
    items['Stop server'].call
    items['Status'].call
    assert_equal 1, @app.starts
    assert_equal 1, @app.stops
    assert_equal 0, @app.status_calls
    assert_equal [
      "MCP server started at #{FakeApp::BOUND_URL}.",
      'MCP server stopped.',
      "MCP server is stopped. Saved port: 7891. Use #{SkRubyMcp::PluginMenu::MENU_HINT} → Start server."
    ], @notifier.messages
    assert_equal [SkRubyMcp::PluginMenu::STOP_CONFIRM], @notifier.confirms
  end

  def test_start_server_reports_already_running_and_bind_failure
    @app.running = true
    assert_equal :already_running, @menu.start_server
    assert_equal 0, @app.starts
    assert_equal ["MCP server is already running at #{FakeApp::BOUND_URL}."], @notifier.messages
    refute_includes @notifier.messages.first, ':7891/'

    @app.running = false
    @app.start_result = false
    @notifier.messages.clear
    assert_equal :start_failed, @menu.start_server
    assert_equal 1, @app.starts
    assert_equal 1, @app.status_calls
    assert_includes @notifier.messages.first, 'could not start'
    assert_includes @notifier.messages.first, @app.listen_url
    refute_includes @notifier.messages.first, FakeApp::BOUND_URL
    assert_includes @notifier.messages.first, 'already be in use'
  end

  def test_stop_server_confirms_and_can_be_cancelled
    assert_equal :not_running, @menu.stop_server
    assert_equal 0, @app.stops
    assert_equal ['MCP server is not running.'], @notifier.messages

    @app.running = true
    @notifier.confirm = false
    @notifier.messages.clear
    assert_equal :cancelled, @menu.stop_server
    assert_equal 0, @app.stops
    assert_empty @notifier.messages
  end

  def test_open_settings_cancelled_does_not_write
    @dialog.answers = false
    assert_equal :cancelled, @menu.open_settings
    assert_equal 1, @dialog.asks
    assert_empty @notifier.messages
    assert_equal 7891, SkRubyMcp::Settings.get('port')
  end

  def test_open_settings_invalid_shape_notifies_and_skips_write
    @dialog.answers = ['7892']
    assert_equal :invalid, @menu.open_settings
    assert_equal ['Settings were not saved.'], @notifier.messages
    assert_equal 7891, SkRubyMcp::Settings.get('port')
  end

  def test_open_settings_restarts_running_server_when_port_changes
    @app.running = true
    answers = Form.current_values
    answers[Form::FIELDS.index { |field| field.key == 'port' }] = '7892'
    @dialog.answers = answers
    assert_equal :restarted, @menu.open_settings
    assert_equal 1, @app.stops
    assert_equal 1, @app.starts
    assert_equal [SkRubyMcp::PluginMenu::RESTART_CONFIRM], @notifier.confirms
    assert @notifier.messages.first.start_with?("MCP server restarted at #{FakeApp::BOUND_URL}.")
    assert_includes @notifier.messages.first, 'Settings saved.'
    refute_includes @notifier.messages.first, 'secret'
  end

  def test_open_settings_does_not_start_a_stopped_server
    answers = Form.current_values
    answers[Form::FIELDS.index { |field| field.key == 'port' }] = '7892'
    @dialog.answers = answers
    assert_equal :saved, @menu.open_settings
    assert_equal 0, @app.starts
    assert_equal 0, @app.stops
    text = @notifier.messages.first
    assert text.start_with?('Use ')
    assert_includes text, 'Start server to apply'
    assert_includes text, 'Plugins or Extensions'
    assert_includes text, 'port: 7892'
    assert_operator text.index('Start server'), :<, text.index('port: 7892')
  end

  def test_open_settings_reports_restart_failure
    @app.running = true
    @app.start_result = false
    answers = Form.current_values
    answers[Form::FIELDS.index { |field| field.key == 'port' }] = '7892'
    @dialog.answers = answers
    assert_equal :restart_failed, @menu.open_settings
    assert_equal 1, @app.stops
    assert_equal 1, @app.starts
    assert @notifier.messages.first.start_with?('The MCP server could not restart and is stopped.')
    assert_includes @notifier.messages.first, 'Plugins or Extensions'
    refute @notifier.messages.first.start_with?('Settings saved.')
  end

  def test_open_settings_unchanged_values_do_not_restart
    @app.running = true
    @dialog.answers = Form.current_values
    assert_equal :unchanged, @menu.open_settings
    assert_equal 0, @app.stops
    assert_equal ['No settings changed.'], @notifier.messages
  end

  def test_open_settings_hides_auth_token
    @app.running = true
    answers = Form.current_values
    answers[Form::FIELDS.index { |field| field.key == 'auth_token' }] = 'super-secret'
    @dialog.answers = answers
    @menu.open_settings
    refute_includes @notifier.messages.join, 'super-secret'
    assert_includes @notifier.messages.join, 'auth_token: (set)'
  end

  def test_open_settings_reports_rejected_fields
    answers = Form.current_values
    answers[Form::FIELDS.index { |field| field.key == 'port' }] = '80'
    @dialog.answers = answers
    assert_equal :cancelled, @menu.open_settings
    assert_equal 2, @dialog.asks
    assert_includes @notifier.messages.first, 'Settings were not saved.'
    assert_includes @notifier.messages.first, '1024-65535'
    assert_equal 7891, SkRubyMcp::Settings.get('port')
  end

  def test_open_settings_retries_with_the_draft_then_saves
    bad = Form.current_values
    bad[Form::FIELDS.index { |field| field.key == 'port' }] = '80'
    good = Form.current_values
    good[Form::FIELDS.index { |field| field.key == 'port' }] = '7892'
    @dialog.replies = [bad, good]
    assert_equal :saved, @menu.open_settings
    assert_equal 2, @dialog.asks
    assert_equal 7892, SkRubyMcp::Settings.get('port')
  end

  def test_open_settings_restart_cancelled_does_not_write
    @app.running = true
    @notifier.confirm = false
    answers = Form.current_values
    answers[Form::FIELDS.index { |field| field.key == 'port' }] = '7892'
    @dialog.answers = answers
    assert_equal :cancelled, @menu.open_settings
    assert_equal 7891, SkRubyMcp::Settings.get('port')
    assert_equal 0, @app.stops
    assert_equal [SkRubyMcp::PluginMenu::RESTART_CONFIRM], @notifier.confirms
    assert_equal ['Settings were not saved.'], @notifier.messages
  end
end
