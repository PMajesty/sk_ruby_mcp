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
    bridge = SketchupDocumentBridge.new(attach: FakeAttach.new)
    assert bridge.remote?('//server/share/house.skp')
  end

  def test_remote_predicate_uses_the_mount_table
    bridge = SketchupDocumentBridge.new(attach: FakeAttach.new)
    def bridge.mount_entries
      [['/', 'apfs'], ['/Volumes/Share', 'smbfs']]
    end
    refute bridge.remote?('/tmp/house.skp')
    assert bridge.remote?('/Volumes/Share/house.skp')
  end

  def test_a_real_tmp_file_is_not_remote
    dir = Dir.mktmpdir
    begin
      skp = File.join(dir, 'house.skp')
      File.write(skp, 'skp')
      bridge = SketchupDocumentBridge.new(attach: FakeAttach.new)
      refute bridge.remote?(skp)
      refute bridge.remote?(File.realpath(skp))
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  def test_remote_predicate_allows_a_local_file_when_mount_is_unknown
    bridge = SketchupDocumentBridge.new(attach: FakeAttach.new)
    def bridge.mount_entries
      []
    end
    refute bridge.remote?('/tmp/house.skp')
    refute bridge.remote?('/Users/me/project/house.skp')
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
end
