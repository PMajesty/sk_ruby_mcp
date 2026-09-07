# frozen_string_literal: true

require_relative 'test_helper'

class AppTest < Minitest::Test
  App = SkRubyMcp::App
  Settings = SkRubyMcp::Settings

  def setup
    @store = {}
    @previous_sketchup = TestSupport.replace_sketchup(TestSupport.sketchup_defaults_store(@store))
    @previous_sink = SkRubyMcp::Log.sink
    @io = StringIO.new
    SkRubyMcp::Log.sink = @io
    reset_app
  end

  def teardown
    restore_build_server
    reset_app
    SkRubyMcp::Log.sink = @previous_sink
    TestSupport.restore_sketchup(@previous_sketchup)
  end

  def test_failed_start_clears_server_session_and_runtime_settings
    stub_build_server(FailingServer.new)
    refute App.start
    assert_nil App.server
    assert_nil App.document_session
    assert_nil App.instance_variable_get(:@runtime_settings)
  end

  def test_print_status_redacts_token_and_ignores_auto_start_as_stale
    Settings.set('auth_token', 'secret-token')
    App.instance_variable_set(:@server, RunningServer.new)
    App.instance_variable_set(:@runtime_settings, Settings.all)
    Settings.set('auto_start', false)
    App.print_status
    text = @io.string
    refute_includes text, 'secret-token'
    assert_includes text, '(set)'
    refute_includes text, 'settings changed'

    Settings.set('port', 7892)
    App.print_status
    assert_includes @io.string, 'settings changed; stop and start the MCP server to apply'
  end

  def test_instructions_point_at_start_server_when_the_server_is_stopped
    assert_includes App::INSTRUCTIONS, 'Start server'
    assert_includes App::INSTRUCTIONS, 'Plugins or Extensions'
    assert_includes App::INSTRUCTIONS, 'ask the architect to use Plugins or Extensions'
    assert_includes App::INSTRUCTIONS, 'wrong port'
    assert_includes App::INSTRUCTIONS, 'Never open dialogs'
    assert_includes App::INSTRUCTIONS, 'point this MCP client at that URL'
    assert_includes App::INSTRUCTIONS, 'Status only for a listening URL'
    assert_includes App::INSTRUCTIONS, 'Status while stopped is not a URL'
    refute_match(/If SketchUp is open, use Plugins/, App::INSTRUCTIONS)
    refute_match(/connection refused means SketchUp is closed or the server is stopped: ask the architect to start SketchUp/, App::INSTRUCTIONS)
  end

  def test_print_status_treats_pack_toggle_as_stale
    App.instance_variable_set(:@server, RunningServer.new)
    App.instance_variable_set(:@runtime_settings, Settings.all)
    Settings.set('architect_pack', false)
    App.print_status
    assert_includes @io.string, 'settings changed; stop and start the MCP server to apply'
  end

  def test_listen_url_uses_the_bound_port_while_running
    Settings.set('port', 7892)
    App.instance_variable_set(:@server, RunningServer.new)
    App.instance_variable_set(:@runtime_settings, Settings.all)
    assert_equal 'http://127.0.0.1:7891/mcp', App.listen_url
    text = App.print_status
    assert_includes text, 'url: http://127.0.0.1:7891/mcp'
    refute_includes text, 'url: http://127.0.0.1:7892/mcp'
    assert_includes @io.string, 'url: http://127.0.0.1:7891/mcp'

    App.instance_variable_set(:@server, nil)
    assert_equal 'http://127.0.0.1:7892/mcp', App.listen_url
    @io.truncate(0)
    @io.rewind
    stopped = App.print_status
    refute_match(%r{url: http://127\.0\.0\.1:\d+/mcp}, stopped)
    assert_includes stopped, 'stopped'
    assert_includes stopped, 'Saved port: 7892'
    assert_includes stopped, 'Start server'
  end

  def test_build_handler_lists_packs_from_settings_at_construction
    handler = listed_handler
    names = tool_names(handler)
    assert_includes names, 'place_box'
    assert_includes names, 'facade_faces'
    instructions = handler.handle(TestSupport.json_rpc('initialize', { 'protocolVersion' => '2025-11-25' }))[:result][:instructions]
    assert_includes instructions, App::PACK_NOTE

    Settings.set('architect_pack', false)
    Settings.set('facade_pack', false)
    handler = listed_handler
    names = tool_names(handler)
    refute_includes names, 'place_box'
    refute_includes names, 'facade_faces'
    instructions = handler.handle(TestSupport.json_rpc('initialize', { 'protocolVersion' => '2025-11-25' }))[:result][:instructions]
    refute_includes instructions, App::PACK_NOTE
  end

  private

  class FailingServer
    def start
      false
    end

    def running?
      false
    end
  end

  class RunningServer
    def running?
      true
    end

    def port
      7891
    end

    def health
      { 'ok' => true }
    end
  end

  def reset_app
    App.instance_variable_set(:@server, nil)
    App.instance_variable_set(:@document_session, nil)
    App.instance_variable_set(:@runtime_settings, nil)
    App.instance_variable_set(:@plugin_menu, nil)
  end

  def listed_handler
    App.send(
      :build_handler,
      SkRubyMcp::Runtime::ToolCallGate.new,
      Object.new,
      Object.new,
      Object.new
    )
  end

  def tool_names(handler)
    handler.handle(TestSupport.json_rpc('tools/list'))[:result][:tools].map { |tool| tool[:name] }
  end

  def stub_build_server(fake)
    klass = App.singleton_class
    klass.send(:alias_method, :__orig_build_server, :build_server)
    klass.send(:define_method, :build_server) do
      instance_variable_set(:@document_session, :session)
      fake
    end
    klass.send(:private, :build_server)
    @build_server_stubbed = true
  end

  def restore_build_server
    return unless @build_server_stubbed

    klass = App.singleton_class
    klass.send(:remove_method, :build_server)
    klass.send(:alias_method, :build_server, :__orig_build_server)
    klass.send(:remove_method, :__orig_build_server)
    klass.send(:private, :build_server)
    @build_server_stubbed = false
  end
end
