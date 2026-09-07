# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'

class SketchupDocumentBridgeTest < Minitest::Test
  SketchupDocumentBridge = SkRubyMcp::Runtime::SketchupDocumentBridge

  class FakeAttach
    attr_reader :actions
    attr_accessor :model, :needs_activation

    def initialize
      @actions = []
      @model = nil
      @needs_activation = true
    end

    def current_model
      @model
    end

    def document_count
      @model ? 1 : 0
    end

    def macos?
      true
    end

    def needs_activation?
      @needs_activation
    end

    def file_new
      @actions << :file_new
      @model = :attached
    end

    def activate_app
      @actions << :activate
    end

    def peek_active_model
      @actions << :peek
      @model
    end

    def create_blank
      file_new
      activate_app if needs_activation?
      peek_active_model
    end
  end

  class WinAttach < FakeAttach
    def macos?
      false
    end
  end

  def test_create_new_uses_one_attach_helper
    attach = FakeAttach.new
    bridge = SketchupDocumentBridge.new(attach: attach)
    assert_equal :attached, bridge.create_new
    assert_equal %i[file_new activate peek], attach.actions
  end

  def test_create_new_skips_activate_when_the_platform_does_not_need_it
    attach = FakeAttach.new
    attach.needs_activation = false
    bridge = SketchupDocumentBridge.new(attach: attach)
    assert_equal :attached, bridge.create_new
    assert_equal %i[file_new peek], attach.actions
  end

  def test_file_predicate_uses_the_local_filesystem
    dir = Dir.mktmpdir
    begin
      skp = File.join(dir, 'house.skp')
      File.write(skp, 'skp')
      bridge = SketchupDocumentBridge.new(attach: FakeAttach.new)
      assert bridge.file?(skp)
      refute bridge.file?(File.join(dir, 'missing.skp'))
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  def test_dispatch_blank_copies_the_bundled_file_and_opens_it
    attach = FakeAttach.new
    opened = []
    bridge = Class.new(SketchupDocumentBridge) do
      define_method(:open_path) { |path| opened << path }
    end.new(attach: attach)
    dest = bridge.dispatch_blank
    assert dest
    assert File.file?(dest)
    assert_includes File.basename(dest), 'sk-mcp-new-'
    assert_equal [dest], opened
  ensure
    File.delete(dest) if dest && File.file?(dest)
  end

  def test_remote_predicate_treats_unc_as_remote
    probe = SkRubyMcp::Runtime::PathProbe.new
    assert probe.remote?('//server/share/house.skp')
    assert SketchupDocumentBridge.new(attach: FakeAttach.new, path_probe: probe).remote?('//server/share/house.skp')
  end

  def test_remote_predicate_uses_the_mount_table
    probe = SkRubyMcp::Runtime::PathProbe.new
    def probe.mount_entries
      [['/', 'apfs'], ['/Volumes/Share', 'smbfs']]
    end
    refute probe.remote?('/tmp/house.skp')
    assert probe.remote?('/Volumes/Share/house.skp')
  end

  def test_a_real_tmp_file_is_not_remote
    dir = Dir.mktmpdir
    begin
      skp = File.join(dir, 'house.skp')
      File.write(skp, 'skp')
      probe = SkRubyMcp::Runtime::PathProbe.new
      refute probe.remote?(skp)
      refute probe.remote?(File.realpath(skp))
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  def test_remote_predicate_allows_a_local_file_when_mount_is_unknown
    probe = SkRubyMcp::Runtime::PathProbe.new
    def probe.mount_entries
      []
    end
    refute probe.remote?('/tmp/house.skp')
    refute probe.remote?('/Users/me/project/house.skp')
  end

  def test_dispatch_blank_does_not_reuse_an_existing_dest
    attach = FakeAttach.new
    opened = []
    bridge = Class.new(SketchupDocumentBridge) do
      define_method(:open_path) { |path| opened << path }
    end.new(attach: attach)
    first = bridge.dispatch_blank
    second = bridge.dispatch_blank
    refute_equal first, second
    assert File.file?(first)
    assert File.file?(second)
  ensure
    [first, second].each { |path| File.delete(path) if path && File.file?(path) }
  end

  def test_dispatch_blank_is_nil_when_the_bundled_file_is_missing
    attach = FakeAttach.new
    bridge = Class.new(SketchupDocumentBridge) do
      define_method(:bundled_blank_path) { '/no/such/blank.skp' }
    end.new(attach: attach)
    assert_nil bridge.dispatch_blank
  end

  def test_windows_host_defers_open_until_the_next_tick
    assert SketchupDocumentBridge.new(attach: WinAttach.new).defer_open_until_next_tick?
    refute SketchupDocumentBridge.new(attach: FakeAttach.new).defer_open_until_next_tick?
  end

  def test_drive_letter_paths_do_not_read_the_unix_mount_table
    probe = SkRubyMcp::Runtime::PathProbe.new
    def probe.mount_entries
      raise 'unix mount table must not be used for a drive letter'
    end
    def probe.windows_drive_type(_root)
      3
    end
    refute probe.remote?('C:/Users/me/house.skp')
    refute probe.remote?('C:\\Users\\me\\house.skp')
  end

  def test_windows_open_accepts_a_success_status
    with_sketchup_open_file(0) do
      bridge = SketchupDocumentBridge.new(attach: WinAttach.new)
      assert_equal :opened, bridge.open_path('C:/models/house.skp')
    end
  end

  def test_windows_mapped_drive_is_remote
    probe = SkRubyMcp::Runtime::PathProbe.new
    def probe.windows_drive_type(_root)
      4
    end
    assert probe.remote?('Z:/share/house.skp')
  end

  def test_windows_unknown_or_missing_root_is_remote
    probe = SkRubyMcp::Runtime::PathProbe.new
    def probe.windows_drive_type(_root)
      1
    end
    assert probe.remote?('Z:/house.skp')

    def probe.windows_drive_type(_root)
      raise 'GetDriveTypeW failed'
    end
    assert probe.remote?('Z:/house.skp')
  end

  def test_windows_open_accepts_a_more_recent_success_status
    with_sketchup_open_file(5) do
      bridge = SketchupDocumentBridge.new(attach: WinAttach.new)
      assert_equal :opened, bridge.open_path('C:/models/house.skp')
    end
  end

  def test_dispatch_blank_returns_nil_when_open_fails
    opened = []
    bridge = Class.new(SketchupDocumentBridge) do
      define_method(:open_path) do |path|
        opened << path
        raise StandardError, 'refused'
      end
    end.new(attach: WinAttach.new)
    assert_nil bridge.dispatch_blank
    dest = opened.first
    assert dest
    refute File.file?(dest)
  end

  def test_windows_open_raises_when_sketchup_refuses_the_file
    with_sketchup_open_file(false) do
      bridge = SketchupDocumentBridge.new(attach: WinAttach.new)
      error = assert_raises(StandardError) { bridge.open_path('C:/models/house.skp') }
      assert_includes error.message, 'refused to open'
    end
  end

  def with_sketchup_open_file(status, version: '22.0')
    previous = Object.const_defined?(:Sketchup) ? Object.const_get(:Sketchup) : nil
    sketchup = Module.new
    sketchup.define_singleton_method(:version) { version }
    sketchup.define_singleton_method(:open_file) { |*_args, **_kwargs| status }
    model = Module.new
    model.const_set(:LOAD_STATUS_SUCCESS, 0)
    model.const_set(:LOAD_STATUS_SUCCESS_MORE_RECENT, 5)
    sketchup.const_set(:Model, model)
    Object.send(:remove_const, :Sketchup) if Object.const_defined?(:Sketchup)
    Object.const_set(:Sketchup, sketchup)
    yield
  ensure
    Object.send(:remove_const, :Sketchup) if Object.const_defined?(:Sketchup)
    Object.const_set(:Sketchup, previous) if previous
  end
end
