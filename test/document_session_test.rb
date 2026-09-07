# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'

class DocumentSessionTest < Minitest::Test
  DocumentSession = SkRubyMcp::Runtime::DocumentSession
  ModelSnapshot = SkRubyMcp::Runtime::ModelSnapshot

  class FakeDoc
    attr_accessor :path, :title, :guid, :modified, :entity_count, :selection_count

    def initialize(path: nil, title: '', guid: 'g1', modified: false, entity_count: 1, selection_count: 0)
      @path = path
      @title = title
      @guid = guid
      @modified = modified
      @entity_count = entity_count
      @selection_count = selection_count
    end

    def valid?
      true
    end

    def modified?
      @modified
    end

    def entities
      Array.new(@entity_count)
    end

    def selection
      Array.new(@selection_count)
    end
  end

  class PathView
    def initialize(bridge)
      @bridge = bridge
    end

    def remote?(path)
      @bridge.remote?(path)
    end

    def file?(path)
      @bridge.file?(path)
    end

    def directory?(path)
      @bridge.directory?(path)
    end

    def realpath(path)
      @bridge.realpath(path)
    end
  end

  class FakeBridge
    attr_accessor :model, :after_open, :after_close, :blank, :open_blocks, :documents, :count_unknown, :fail_dispatch, :force_remote, :defer_open
    attr_reader :actions

    def initialize(model: nil)
      @model = model
      @actions = []
      @open_blocks = false
      @count_unknown = false
      @defer_open = false
    end

    def current_model
      @model
    end

    def snapshot
      SkRubyMcp::Runtime::ModelSnapshotFactory.from_model(@model)
    end

    def canonical(path)
      return nil if path.nil? || path.to_s.empty?

      File.exist?(path) ? File.realpath(path) : File.expand_path(path)
    end

    def paths_equal?(left, right)
      a = canonical(left)
      b = canonical(right)
      !a.nil? && !b.nil? && a.downcase == b.downcase
    end

    def document_count
      return nil if @count_unknown
      return @documents unless @documents.nil?

      @model ? 1 : 0
    end

    def file?(path)
      File.file?(path.to_s)
    end

    def directory?(path)
      File.directory?(path.to_s)
    end

    def realpath(path)
      File.exist?(path.to_s) ? File.realpath(path.to_s) : File.expand_path(path.to_s)
    end

    def expand_path(path)
      File.expand_path(path.to_s)
    end

    def remote?(path)
      return true if @force_remote
      text = path.to_s.tr('\\', '/')
      text.start_with?('//') || text.include?('/Volumes/')
    end

    def host_major
      @host_major || 22
    end

    def host_major=(value)
      @host_major = value
    end

    def suppress_version_dialog?
      @suppress_version_dialog == true
    end

    def suppress_version_dialog=(value)
      @suppress_version_dialog = value
    end

    def defer_open_until_next_tick?
      @defer_open == true
    end

    def path_probe
      @path_view ||= PathView.new(self)
    end

    def open_path(path)
      @actions << [:open, path]
      @model = @after_open unless @open_blocks
    end

    def create_new
      @actions << [:new]
      @model = @blank
      @model
    end

    def dispatch_blank
      @actions << [:blank]
      return nil if @fail_dispatch

      dest = File.join(Dir.tmpdir, "sk-mcp-new-#{Process.pid}.skp")
      @model = @after_open || @blank
      dest
    end

    def close(_model, ignore_changes)
      @actions << [:close, ignore_changes]
      if @after_close
        @model = @after_close
        @after_close = nil
      else
        @model = nil
      end
    end

    def save(model)
      @actions << [:save, model.path]
      model.modified = false
    end

    def save_as(model, path)
      @actions << [:save_as, path]
      model.path = path
      model.title = File.basename(path, '.skp')
      model.modified = false
    end

    def save_copy(_model, path, version: nil)
      @actions << [:save_copy, path, version]
      File.write(path, 'copy')
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @skp = File.join(@dir, 'house.skp')
    TestSupport.write_skp(@skp)
    @skp = File.realpath(@skp)
    @bridge = FakeBridge.new
    @cleaned = 0
    @session = DocumentSession.new(bridge: @bridge, locals_cleaner: -> { @cleaned += 1 })
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def name_current(path, title)
    @bridge.model = FakeDoc.new(path: path, title: title)
    named = @session.open(path: path)
    assert named.already_open
  end

  def test_status_without_document_tells_the_agent_what_to_call
    result = @session.status
    assert result.ok
    assert_equal 'no_document', result.state
    assert_includes result.next, 'model_new'
    assert_includes result.next, 'model_open'
  end

  def test_status_with_document_is_active_without_a_canned_next
    @bridge.model = FakeDoc.new(path: @skp, title: 'house')
    result = @session.status
    assert_equal 'active', result.state
    assert_equal @skp, result.snapshot.path
    assert_nil result.next
  end

  def test_open_rejects_relative_and_missing_paths
    relative = @session.open(path: 'house.skp')
    refute relative.ok
    assert_equal 'invalid_model_path', relative.code
    assert_includes relative.message, 'C:'

    missing = @session.open(path: File.join(@dir, 'nope.skp'))
    refute missing.ok
    assert_includes missing.message, 'existing file'
  end

  def test_open_is_idempotent_when_the_same_file_is_focused
    @bridge.model = FakeDoc.new(path: @skp, title: 'house')
    result = @session.open(path: @skp)
    assert result.ok
    assert result.already_open
    assert_equal 'active', result.state
    assert_empty @bridge.actions
  end

  def test_open_switches_by_saving_and_closing_the_current_file
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    name_current(other, 'other')
    @bridge.model.modified = true
    @bridge.after_open = FakeDoc.new(path: @skp, title: 'house')

    result = @session.open(path: @skp, if_unsaved: 'save')
    assert result.ok
    assert_equal 'active', result.state
    assert_equal @skp, result.snapshot.path
    assert_equal [[:save, other], [:close, true], [:open, @skp]], @bridge.actions
    assert_equal 1, @cleaned
    assert result.locals_cleared
    assert_includes result.next, 'constants and methods are gone'
    refute_includes result.next, 'unset'
  end

  def test_open_refuses_save_on_dirty_untitled
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: true)
    result = @session.open(path: @skp, if_unsaved: 'save')
    refute result.ok
    assert_equal 'untitled_needs_path', result.code
    assert_equal 'model_save', result.instead
    assert_empty @bridge.actions
  end

  def test_open_refuses_untitled_modified_unless_discard_requested
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: true)
    result = @session.open(path: @skp)
    refute result.ok
    assert_equal 'unsaved_changes', result.code
    assert_equal 'model_save', result.instead
    assert_includes result.next, 'model_save'
    refute_includes result.next, 'if_unsaved=save'
    assert_empty @bridge.actions

    @bridge.after_open = FakeDoc.new(path: @skp, title: 'house')
    discarded = @session.open(path: @skp, if_unsaved: 'discard')
    assert discarded.ok
    assert_equal [[:close, true], [:open, @skp]], @bridge.actions
  end

  def test_open_refuses_to_save_an_unnamed_dirty_file
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    @bridge.model = FakeDoc.new(path: other, title: 'other', modified: true)
    result = @session.open(path: @skp, if_unsaved: 'save')
    refute result.ok
    assert_equal 'unnamed_save', result.code
    assert_empty @bridge.actions
  end

  def test_open_refuses_a_newer_major_when_the_host_cannot_suppress_the_dialog
    newer = File.join(@dir, 'from-2025.skp')
    TestSupport.write_skp(newer, major: 25, minor: 0, build: 1)
    result = @session.open(path: newer)
    refute result.ok
    assert_equal 'newer_sketchup_file', result.code
    assert_includes result.message, 'SketchUp 2025'
    assert_includes result.message, '2022'
    assert_empty @bridge.actions
  end

  def test_open_allows_a_newer_major_when_the_host_can_suppress_the_dialog
    newer = File.join(@dir, 'from-2025.skp')
    TestSupport.write_skp(newer, major: 25, minor: 0, build: 1)
    @bridge.host_major = 26
    @bridge.suppress_version_dialog = true
    @bridge.after_open = FakeDoc.new(path: File.realpath(newer), title: 'from-2025')
    result = @session.open(path: newer)
    assert result.ok
    assert_includes @bridge.actions, [:open, File.realpath(newer)]
  end

  def test_open_returns_opening_when_focus_does_not_switch_yet
    @bridge.open_blocks = true
    result = @session.open(path: @skp)
    assert result.ok
    assert_equal 'opening', result.state
    assert_includes result.next, 'model_status'
    assert_nil result.snapshot
  end

  def test_status_after_open_reports_opened_once
    @bridge.open_blocks = true
    first = @session.open(path: @skp)
    assert_equal 'opening', first.state
    refute first.changed
    @bridge.model = FakeDoc.new(path: @skp, title: 'house')
    done = @session.status
    assert_equal 'active', done.state
    assert_equal 'opened', done.changed
    later = @session.status
    assert_equal 'active', later.state
    assert_nil later.changed
  end

  def test_opening_status_omits_a_leftover_untitled
    @bridge.open_blocks = true
    @bridge.model = FakeDoc.new(path: nil, title: '', entity_count: 1)
    @session.open(path: @skp)
    @bridge.model = FakeDoc.new(path: nil, title: '', entity_count: 1)
    status = @session.status
    assert_equal 'opening', status.state
    assert_nil status.snapshot
    refute status.model_present if status.respond_to?(:model_present)
    assert_equal @skp, status.requested_path
  end

  def test_new_document_closes_now_and_creates_on_status
    name_current(@skp, 'house')
    @bridge.blank = FakeDoc.new(path: nil, title: '', entity_count: 0)
    first = @session.new_document
    assert first.ok
    assert_equal 'opening', first.state
    assert_includes first.next, 'Do not call model_new again'
    assert_equal [[:close, true]], @bridge.actions
    assert @session.pending?

    same_tick = @session.status
    assert_equal 'opening', same_tick.state
    assert_equal [[:close, true]], @bridge.actions

    @session.begin_tick
    second = @session.status
    assert_equal 'active', second.state
    assert_equal 'created', second.changed
    assert_nil second.snapshot.path
    assert_equal [[:close, true], [:new]], @bridge.actions
    assert_equal 1, @cleaned
    later = @session.status
    assert_nil later.changed
  end

  def test_new_document_from_empty_creates_on_a_later_status
    @bridge.blank = FakeDoc.new(path: nil, title: '', entity_count: 0)
    first = @session.new_document
    assert first.ok
    assert_equal 'opening', first.state
    assert_empty @bridge.actions
    @session.begin_tick
    second = @session.status
    assert_equal 'active', second.state
    assert_equal 'created', second.changed
    assert_equal [[:new]], @bridge.actions
  end

  def test_new_document_closes_template_untitled_then_dispatches
    name_current(@skp, 'house')
    person = FakeDoc.new(path: nil, title: '', entity_count: 5)
    @bridge.define_singleton_method(:create_new) do
      @actions << [:new]
      @model = person
      person
    end
    dest = File.join(@dir, 'sk-mcp-new-empty.skp')
    @bridge.define_singleton_method(:dispatch_blank) do
      @actions << [:blank]
      TestSupport.write_skp(dest)
      @model = FakeDoc.new(path: dest, title: 'sk-mcp-new-empty', entity_count: 0)
      dest
    end
    first = @session.new_document
    assert_equal 'opening', first.state
    @session.begin_tick
    after_new = @session.status
    assert_equal 'opening', after_new.state
    assert_includes @bridge.actions, [:new]
    refute_includes @bridge.actions, [:blank]
    @session.begin_tick
    after_close = @session.status
    assert_equal 'opening', after_close.state
    assert_equal 2, @bridge.actions.count { |action| action == [:close, true] }
    @session.begin_tick
    done = @session.status
    assert_equal 'active', done.state
    assert_equal 'created', done.changed
    assert done.temporary
    assert_includes @bridge.actions, [:blank]
  end

  def test_save_requires_path_for_untitled
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: true)
    result = @session.save
    refute result.ok
    assert_equal 'path_required', result.code

    saved = @session.save(path: File.join(@dir, 'new.skp'))
    assert saved.ok
    assert saved.saved_as
    assert_equal 'new', saved.snapshot.title
  end

  def test_save_copy_leaves_the_focused_path
    name_current(@skp, 'house')
    copy = File.join(File.realpath(@dir), 'house-copy.skp')
    result = @session.save(mode: 'copy', path: File.join(@dir, 'house-copy.skp'))
    assert result.ok
    assert result.copied
    refute result.saved_as
    assert_equal copy, result.copy_path
    assert_equal @skp, result.snapshot.path
    assert_equal [[:save_copy, copy, nil]], @bridge.actions
    assert File.file?(copy)
  end

  def test_close_saves_modified_pathed_document
    name_current(@skp, 'house')
    @bridge.model.modified = true
    result = @session.close(if_unsaved: 'save')
    assert result.ok
    assert_equal 'no_document', result.state
    assert_equal [[:save, @skp], [:close, true]], @bridge.actions
    assert result.locals_cleared
  end

  def test_close_untitled_modified_requires_discard
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: true)
    result = @session.close
    refute result.ok
    assert_equal 'unsaved_changes', result.code

    discarded = @session.close(if_unsaved: 'discard')
    assert discarded.ok
    assert_equal [[:close, true]], @bridge.actions
  end

  def test_close_is_refused_while_open_is_in_progress
    @bridge.open_blocks = true
    opening = @session.open(path: @skp)
    assert_equal 'opening', opening.state
    refused = @session.close(if_unsaved: 'discard')
    refute refused.ok
    assert_equal 'open_in_progress', refused.code
  end

  def test_new_document_fails_if_a_leftover_stays_focused
    leftover = FakeDoc.new(path: @skp, title: 'house', modified: false)
    @bridge.model = leftover
    @bridge.define_singleton_method(:close) { |*_args| nil }
    result = @session.new_document
    refute result.ok
    assert_equal 'leftover_document', result.code
  end

  def test_new_document_consumes_an_untitled_left_after_close
    name_current(@skp, 'house')
    person = FakeDoc.new(path: nil, title: '', entity_count: 5)
    @bridge.after_close = person
    dest = File.join(@dir, 'sk-mcp-new-after-close.skp')
    @bridge.define_singleton_method(:dispatch_blank) do
      @actions << [:blank]
      TestSupport.write_skp(dest)
      @model = FakeDoc.new(path: dest, title: 'sk-mcp-new-after-close', entity_count: 0)
      dest
    end
    first = @session.new_document
    assert_equal 'opening', first.state
    refute_includes @bridge.actions, [:new]
    @session.begin_tick
    after_close = @session.status
    assert_equal 'opening', after_close.state
    @session.begin_tick
    done = @session.status
    assert_equal 'active', done.state
    assert_equal 'created', done.changed
    assert done.temporary
    assert_includes @bridge.actions, [:blank]
  end

  def test_status_keeps_a_failed_open_instead_of_calling_leftover_active
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    @bridge.open_blocks = true
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: false)
    session = short.new(bridge: @bridge)
    session.open(path: @skp)
    status = session.status
    refute status.ok
    assert_equal 'model_open_timeout', status.code
    refute_equal 'active', status.state
  end

  def test_open_timeout_reopens_the_previous_named_file
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    name_current(other, 'other')
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    session = short.new(bridge: @bridge)
    session.open(path: other)
    @bridge.open_blocks = true
    session.open(path: @skp)
    status = session.status
    refute status.ok
    assert_equal 'model_open_timeout', status.code
    assert_includes status.message, 'previous file'
    assert session.pending?
  end

  def test_open_after_pending_completes_still_opens_the_requested_path
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    @bridge.open_blocks = true
    first = @session.open(path: other)
    assert_equal 'opening', first.state
    @bridge.open_blocks = false
    @bridge.model = FakeDoc.new(path: other, title: 'other')
    @bridge.after_open = FakeDoc.new(path: @skp, title: 'house')
    second = @session.open(path: @skp)
    assert second.ok
    assert_equal 'active', second.state
    assert_equal @skp, second.snapshot.path
    assert_includes @bridge.actions, [:open, @skp]
  end

  def test_leftover_failure_stays_until_the_caller_closes
    leftover = FakeDoc.new(path: @skp, title: 'house')
    name_current(@skp, 'house')
    first = @session.new_document
    assert_equal 'opening', first.state
    @session.begin_tick
    @bridge.define_singleton_method(:create_new) do
      @actions << [:new]
      @model = leftover
      leftover
    end
    failed = @session.status
    refute failed.ok
    assert_equal 'leftover_document', failed.code
    assert_includes failed.next, 'model_close'
    assert_includes failed.next, 'then model_new'
    refute_includes failed.next, 'discard=true, then model_new'
    again = @session.status
    refute again.ok
    assert_equal 'leftover_document', again.code
    refute_equal 'active', again.state
  end

  def test_close_reports_a_modified_leftover
    name_current(@skp, 'house')
    leftover = FakeDoc.new(path: nil, title: '', modified: true)
    @bridge.define_singleton_method(:close) do |*_args|
      @actions << [:close, true]
      @model = leftover
    end
    result = @session.close(if_unsaved: 'discard')
    assert result.ok
    assert_equal 'active', result.state
    assert result.snapshot.untitled?
    assert result.snapshot.modified
  end

  def test_close_discards_an_unmodified_leftover_untitled
    name_current(@skp, 'house')
    @bridge.after_close = FakeDoc.new(path: nil, title: '', modified: false)
    result = @session.close(if_unsaved: 'discard')
    assert result.ok
    assert_equal 'no_document', result.state
    assert_equal 2, @bridge.actions.count { |action| action[0] == :close }
  end

  def test_close_of_a_dirty_named_file_reports_saved
    name_current(@skp, 'house')
    @bridge.model.modified = true
    result = @session.close(if_unsaved: 'save')
    assert result.ok
    assert result.saved
    assert_equal 'no_document', result.state
  end

  def test_create_times_out_instead_of_staying_opening
    name_current(@skp, 'house')
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    session = short.new(bridge: @bridge)
    session.open(path: @skp)
    @bridge.define_singleton_method(:create_new) { @actions << [:new]; @model = nil; nil }
    first = session.new_document
    assert_equal 'opening', first.state
    session.begin_tick
    status = session.status
    refute status.ok
    assert_equal 'model_open_timeout', status.code
  end

  def test_new_document_dispatches_a_temp_blank_on_a_later_tick
    name_current(@skp, 'house')
    @bridge.define_singleton_method(:create_new) do
      @actions << [:new]
      @model = nil
      nil
    end
    dest = File.join(@dir, 'sk-mcp-new-dispatch.skp')
    @bridge.define_singleton_method(:dispatch_blank) do
      @actions << [:blank]
      TestSupport.write_skp(dest)
      @model = FakeDoc.new(path: dest, title: 'sk-mcp-new-dispatch')
      dest
    end
    first = @session.new_document
    assert_equal 'opening', first.state
    @session.begin_tick
    second = @session.status
    assert_equal 'opening', second.state
    assert_equal [[:close, true], [:new]], @bridge.actions
    @session.begin_tick
    third = @session.status
    assert_equal 'active', third.state
    assert_equal 'created', third.changed
    assert third.temporary
    assert_includes @bridge.actions, [:blank]
  end

  def test_save_reports_failure_when_sketchup_refuses
    name_current(@skp, 'house')
    @bridge.define_singleton_method(:save) do |_model|
      @actions << [:save_refused]
      raise StandardError, 'SketchUp refused to save the document'
    end
    result = @session.save
    refute result.ok
    assert_equal 'model_save_failed', result.code
    assert_includes result.next, 'model_status'
    refute_includes result.next, 'Call model_new for a blank'
  end

  def test_ruby_refusal_covers_pending_and_sticky_leftover
    @bridge.open_blocks = true
    @session.open(path: @skp)
    refusal = @session.ruby_refusal
    assert_equal 'DocumentOpening', refusal[:class]
    refute refusal[:model_present]

    leftover = FakeDoc.new(path: @skp, title: 'house')
    session = DocumentSession.new(bridge: @bridge)
    @bridge.open_blocks = false
    @bridge.model = leftover
    named = session.open(path: @skp)
    assert named.already_open
    first = session.new_document
    assert_equal 'opening', first.state
    session.begin_tick
    @bridge.define_singleton_method(:create_new) do
      @actions << [:new]
      @model = leftover
      leftover
    end
    failed = session.status
    refute failed.ok
    sticky = session.ruby_refusal
    assert_equal 'leftover_document', sticky[:class]
  end

  def test_note_external_switch_clears_locals_only_when_focus_changes
    @bridge.model = FakeDoc.new(path: @skp, title: 'house', guid: 'g-house')
    @session.note_external_switch
    assert_equal 1, @cleaned
    @session.note_external_switch
    assert_equal 1, @cleaned
    result = @session.save
    refute result.ok
    assert_equal 'unnamed_save', result.code
  end

  def test_untitled_modified_next_does_not_force_close
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: true)
    result = @session.open(path: @skp)
    refute result.ok
    assert_equal 'unsaved_changes', result.code
    assert_includes result.next, 'if_unsaved=discard'
  end

  def test_paths_equal_ignores_case
    assert @bridge.paths_equal?('/tmp/sk-mcp-case/house.skp', '/tmp/sk-mcp-case/HOUSE.skp')
  end

  def test_two_status_calls_on_one_tick_do_not_dispatch_blank
    name_current(@skp, 'house')
    @bridge.define_singleton_method(:create_new) do
      @actions << [:new]
      @model = nil
      nil
    end
    dest = File.join(@dir, 'sk-mcp-new-same-tick.skp')
    @bridge.define_singleton_method(:dispatch_blank) do
      @actions << [:blank]
      TestSupport.write_skp(dest)
      dest
    end
    @session.new_document
    @session.begin_tick
    first = @session.status
    second = @session.status
    assert_equal 'opening', first.state
    assert_equal 'opening', second.state
    assert_equal [[:close, true], [:new]], @bridge.actions
    refute_includes @bridge.actions, [:blank]
  end

  def test_leftover_after_close_stays_failed_on_status
    leftover = FakeDoc.new(path: @skp, title: 'house', modified: false)
    @bridge.model = leftover
    @bridge.define_singleton_method(:close) { |*_args| nil }
    first = @session.new_document
    refute first.ok
    assert_equal 'leftover_document', first.code
    status = @session.status
    refute status.ok
    assert_equal 'leftover_document', status.code
  end

  def test_save_after_pending_completes_saves_the_now_focused_file
    @bridge.open_blocks = true
    opening = @session.open(path: @skp)
    assert_equal 'opening', opening.state
    @bridge.open_blocks = false
    @bridge.model = FakeDoc.new(path: @skp, title: 'house')
    saved = @session.save
    assert saved.ok
    assert_equal 'active', saved.state
    assert_equal 'saved', saved.changed
    assert_includes @bridge.actions, [:save, @skp]
  end

  def test_close_untitled_modified_next_names_discard
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: true)
    result = @session.close
    refute result.ok
    assert_includes result.next, 'if_unsaved=discard'
  end

  def test_revert_reopens_the_saved_path
    name_current(@skp, 'house')
    @bridge.model.modified = true
    @bridge.after_open = FakeDoc.new(path: @skp, title: 'house', modified: false)
    result = @session.revert
    assert result.ok
    assert result.reverted
    assert_equal 'reverted', result.changed
    assert_equal [[:close, true], [:open, @skp]], @bridge.actions
  end

  def test_ruby_refusal_does_not_advance_or_timeout_pending
    @bridge.blank = FakeDoc.new(path: nil, title: '', entity_count: 0)
    first = @session.new_document
    assert_equal 'opening', first.state
    @session.begin_tick
    refusal = @session.ruby_refusal
    assert_equal 'DocumentOpening', refusal[:class]
    assert_includes refusal[:message], 'blank document'
    assert_includes refusal[:next], 'Do not call model_new again'
    assert_empty @bridge.actions
    assert @session.pending?

    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    @bridge.open_blocks = true
    timed = short.new(bridge: @bridge)
    timed.open(path: @skp)
    peek = timed.ruby_refusal
    assert_equal 'DocumentOpening', peek[:class]
    refute_includes peek[:message], 'blank document'
    refute_includes peek[:next], 'Do not call model_new again'
    assert timed.pending?
    refute_equal 'model_open_timeout', peek[:class]
  end

  def test_save_is_refused_while_open_is_in_flight
    @bridge.open_blocks = true
    opening = @session.open(path: @skp)
    assert_equal 'opening', opening.state
    refused = @session.save
    refute refused.ok
    assert_equal 'open_in_progress', refused.code
  end

  def test_timeout_does_not_discard_a_dirty_untitled_leftover
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    @bridge.open_blocks = true
    session = short.new(bridge: @bridge)
    session.open(path: @skp)
    leftover = FakeDoc.new(path: nil, title: '', modified: true)
    @bridge.model = leftover
    status = session.status
    refute status.ok
    assert_equal 'model_open_timeout', status.code
    assert_includes status.next, 'model_save'
    refute_includes status.next, 'retry the document tool'
    assert_same leftover, @bridge.model
    refute_includes @bridge.actions, [:close, true]
  end

  def test_timeout_does_not_discard_a_dirty_unnamed_leftover
    other = File.join(@dir, 'foreign.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    @bridge.open_blocks = true
    session = short.new(bridge: @bridge)
    session.open(path: @skp)
    leftover = FakeDoc.new(path: other, title: 'foreign', modified: true)
    @bridge.model = leftover
    status = session.status
    refute status.ok
    assert_equal 'model_open_timeout', status.code
    assert_includes status.next, 'model_save'
    assert_same leftover, @bridge.model
  end

  def test_dispatch_blank_nil_fails_immediately
    name_current(@skp, 'house')
    @bridge.define_singleton_method(:create_new) do
      @actions << [:new]
      @model = nil
      nil
    end
    @bridge.define_singleton_method(:dispatch_blank) do
      @actions << [:blank]
      nil
    end
    first = @session.new_document
    assert_equal 'opening', first.state
    @session.begin_tick
    second = @session.status
    assert_equal 'opening', second.state
    @session.begin_tick
    third = @session.status
    refute third.ok
    assert_equal 'model_new_failed', third.code
    refute @session.pending?
  end

  def test_create_does_not_file_new_when_a_document_is_already_focused
    first = @session.new_document
    assert_equal 'opening', first.state
    @session.begin_tick
    @bridge.model = FakeDoc.new(path: @skp, title: 'house')
    status = @session.status
    refute status.ok
    assert_equal 'leftover_document', status.code
    refute_includes @bridge.actions, [:new]
  end

  def test_unknown_document_count_is_not_a_leftover
    @bridge.count_unknown = true
    status = @session.status
    refute status.ok
    assert_equal 'document_count_unknown', status.code
    assert_includes status.next, 'Do not call model_close'
    created = @session.new_document
    refute created.ok
    assert_equal 'document_count_unknown', created.code
    opened = @session.open(path: @skp)
    refute opened.ok
    assert_equal 'document_count_unknown', opened.code

    @bridge.model = FakeDoc.new(path: @skp, title: 'house')
    recovered = @session.status
    assert recovered.ok
    assert_equal 'active', recovered.state
  end

  def test_hidden_documents_block_open_and_new
    @bridge.documents = 2
    opened = @session.open(path: @skp)
    refute opened.ok
    assert_equal 'leftover_document', opened.code
    assert_includes opened.next, 'Do not call model_close'
    refute_includes opened.next, 'discard=true, then model_new'
    created = @session.new_document
    refute created.ok
    assert_equal 'leftover_document', created.code
  end

  def test_created_blank_rejects_an_untitled_when_another_document_exists
    @bridge.define_singleton_method(:create_new) do
      @actions << [:new]
      @documents = 2
      @model = FakeDoc.new(path: nil, title: '')
      @model
    end
    first = @session.new_document
    assert_equal 'opening', first.state
    @session.begin_tick
    failed = @session.status
    refute failed.ok
    assert_equal 'leftover_document', failed.code
    assert_includes failed.next, 'only if you want none'
  end

  def test_note_external_switch_does_not_name_a_temp_blank
    name_current(@skp, 'house')
    dest = File.join(@dir, 'sk-mcp-new-observer.skp')
    @bridge.define_singleton_method(:create_new) do
      @actions << [:new]
      @model = nil
      nil
    end
    @bridge.define_singleton_method(:dispatch_blank) do
      @actions << [:blank]
      TestSupport.write_skp(dest)
      @model = FakeDoc.new(path: dest, title: 'sk-mcp-new-observer')
      dest
    end
    @session.new_document
    @session.begin_tick
    @session.status
    @session.begin_tick
    attached = @session.status
    assert attached.temporary
    @session.note_external_switch
    saved = @session.save
    refute saved.ok
    assert_equal 'unnamed_save', saved.code
    assert_includes saved.message, 'temporary'
  end

  def test_open_restores_the_previous_file_when_dispatch_raises
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    name_current(other, 'other')
    requested = @skp
    @bridge.define_singleton_method(:open_path) do |path|
      @actions << [:open, path]
      raise StandardError, 'launch failed' if path == requested
    end
    result = @session.open(path: requested)
    refute result.ok
    assert_equal 'model_open_failed', result.code
    assert_includes result.message, 'previous file'
    assert @session.pending?
  end

  def test_rejects_unc_and_symlink_targets_that_are_not_skp
    remote = @session.open(path: '//server/share/house.skp')
    refute remote.ok
    assert_equal 'invalid_model_path', remote.code
    assert_includes remote.message, 'network share'

    notes = File.join(@dir, 'notes.txt')
    File.write(notes, 'nope')
    link = File.join(@dir, 'fake.skp')
    File.symlink(notes, link)
    linked = @session.open(path: link)
    refute linked.ok
    assert_equal 'not_a_skp_file', linked.code

    @bridge.model = FakeDoc.new(path: nil, title: '', modified: true)
    saved = @session.save(path: '//server/share/out.skp')
    refute saved.ok
    assert_equal 'invalid_model_path', saved.code
  end

  def test_open_rejects_a_path_that_resolves_onto_a_volume_share
    @bridge.define_singleton_method(:file?) { |_path| true }
    @bridge.define_singleton_method(:realpath) { |_path| '/Volumes/Share/house.skp' }
    result = @session.open(path: @skp)
    refute result.ok
    assert_equal 'invalid_model_path', result.code
    assert_includes result.message, 'network share'
  end

  def test_save_resolves_a_symlink_parent_directory
    real = File.join(@dir, 'real')
    Dir.mkdir(real)
    link = File.join(@dir, 'link')
    File.symlink(real, link)
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: true)
    result = @session.save(path: File.join(link, 'out.skp'))
    assert result.ok
    assert_equal File.join(File.realpath(real), 'out.skp'), result.snapshot.path
  end

  def test_timeout_does_not_discard_a_dirty_session_named_file
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    name_current(@skp, 'house')
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    session = short.new(bridge: @bridge)
    session.open(path: @skp)
    @bridge.open_blocks = true
    session.open(path: other)
    leftover = FakeDoc.new(path: @skp, title: 'house', modified: true)
    @bridge.model = leftover
    closes_before = @bridge.actions.count { |action| action[0] == :close }
    status = session.status
    refute status.ok
    assert_equal 'model_open_timeout', status.code
    assert_same leftover, @bridge.model
    assert_equal closes_before, @bridge.actions.count { |action| action[0] == :close }
  end

  def test_close_cannot_clear_a_hidden_leftover
    @bridge.documents = 2
    status = @session.status
    refute status.ok
    assert_equal 'leftover_document', status.code
    closed = @session.close
    refute closed.ok
    assert_equal 'leftover_document', closed.code
    assert_includes closed.next, 'Do not call model_close'
    sticky = @session.status
    assert_equal 'leftover_document', sticky.code
  end

  def test_timeout_restore_failure_stays_failed
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    name_current(other, 'other')
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    session = short.new(bridge: @bridge)
    session.open(path: other)
    @bridge.open_blocks = true
    session.open(path: @skp)
    @bridge.define_singleton_method(:open_path) do |_path|
      raise StandardError, 'restore failed'
    end
    status = session.status
    refute status.ok
    assert_equal 'model_open_timeout', status.code
    assert_includes status.message, 'Could not reopen'
    refute session.pending?
  end

  def test_create_does_not_accept_a_leftover_temp_as_this_blank
    dest = File.join(@dir, 'sk-mcp-new-old.skp')
    TestSupport.write_skp(dest)
    first = @session.new_document
    assert_equal 'opening', first.state
    @session.begin_tick
    @bridge.model = FakeDoc.new(path: dest, title: 'sk-mcp-new-old')
    status = @session.status
    refute status.ok
    assert_equal 'leftover_document', status.code
    refute_includes @bridge.actions, [:new]
  end

  def test_open_does_not_drop_pending_create_as_already_open
    first = @session.new_document
    assert_equal 'opening', first.state
    @bridge.model = FakeDoc.new(path: @skp, title: 'house')
    opened = @session.open(path: @skp)
    refute opened.ok
    assert_equal 'open_in_progress', opened.code
    assert @session.pending?
  end

  def test_revert_restores_when_reopen_raises
    name_current(@skp, 'house')
    @bridge.define_singleton_method(:open_path) do |_path|
      @actions << [:open, @skp]
      raise StandardError, 'launch failed'
    end
    result = @session.revert
    refute result.ok
    assert_equal 'model_revert_failed', result.code
    assert_includes result.message, 'previous file'
  end

  def test_switch_away_reports_model_switch_failed
    name_current(@skp, 'house')
    @bridge.define_singleton_method(:close) do |*_args|
      raise StandardError, 'close failed'
    end
    result = @session.new_document
    refute result.ok
    assert_equal 'switch_failed', result.code
  end

  def test_timeout_leftover_stays_failed_on_the_next_status
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    leftover = FakeDoc.new(path: nil, title: '', modified: true)
    @bridge.open_blocks = true
    session = short.new(bridge: @bridge)
    session.open(path: @skp)
    @bridge.model = leftover
    first = session.status
    refute first.ok
    assert_equal 'model_open_timeout', first.code
    later = session.status
    refute later.ok
    assert_equal 'model_open_timeout', later.code
    refute_equal 'active', later.state
    assert_same leftover, @bridge.model
  end

  def test_status_clears_a_timeout_once_focus_is_readable
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    @bridge.open_blocks = true
    session = short.new(bridge: @bridge)
    session.open(path: @skp)
    timed_out = session.status
    refute timed_out.ok
    assert_equal 'model_open_timeout', timed_out.code
    @bridge.open_blocks = false
    @bridge.model = FakeDoc.new(path: @skp, title: 'house')
    later = session.status
    assert later.ok
    assert_equal 'active', later.state
  end

  def test_dispatch_blank_default_fake_can_return_nil
    name_current(@skp, 'house')
    @bridge.fail_dispatch = true
    @bridge.define_singleton_method(:create_new) do
      @actions << [:new]
      @model = nil
      nil
    end
    @session.new_document
    @session.begin_tick
    @session.status
    @session.begin_tick
    failed = @session.status
    refute failed.ok
    assert_equal 'model_new_failed', failed.code
  end

  def test_timeout_does_not_discard_when_snapshot_is_missing
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    @bridge.open_blocks = true
    session = short.new(bridge: @bridge)
    session.open(path: @skp)
    leftover = Object.new
    def leftover.valid?
      false
    end
    @bridge.model = leftover
    closes_before = @bridge.actions.count { |action| action[0] == :close }
    status = session.status
    refute status.ok
    assert_equal 'model_open_timeout', status.code
    assert_includes status.message, 'snapshot could not be read'
    assert_same leftover, @bridge.model
    assert_equal closes_before, @bridge.actions.count { |action| action[0] == :close }
  end

  def test_save_and_revert_refuse_a_hidden_leftover
    @bridge.documents = 2
    saved = @session.save
    refute saved.ok
    assert_equal 'leftover_document', saved.code
    reverted = @session.revert
    refute reverted.ok
    assert_equal 'leftover_document', reverted.code
    assert_includes reverted.next, 'Do not call model_close'
  end

  def test_create_timeout_from_empty_leaves_an_unmodified_untitled
    leftover = FakeDoc.new(path: nil, title: '', modified: false, entity_count: 4)
    @bridge.define_singleton_method(:create_new) do
      @actions << [:new]
      @model = leftover
      leftover
    end
    first = @session.new_document
    assert_equal 'opening', first.state
    @session.begin_tick
    opening = @session.status
    assert_equal 'opening', opening.state
    assert_same leftover, @bridge.model
    pending = @session.instance_variable_get(:@pending)
    pending[:started_at] = SkRubyMcp::Clock.now - 100
    status = @session.status
    refute status.ok
    assert_equal 'model_open_timeout', status.code
    assert_includes status.message, 'Untitled is still focused'
    assert_same leftover, @bridge.model
    refute_includes @bridge.actions, [:close, true]
  end

  def test_failed_open_does_not_remember_the_path_for_in_place_save
    @bridge.define_singleton_method(:open_path) { |_path| raise StandardError, 'launch failed' }
    opened = @session.open(path: @skp)
    refute opened.ok
    @bridge.model = FakeDoc.new(path: @skp, title: 'house', modified: true)
    saved = @session.save
    refute saved.ok
    assert_equal 'unnamed_save', saved.code
  end

  def test_timeout_clears_pending_before_close
    short = Class.new(DocumentSession)
    short.const_set(:OPEN_DEADLINE_S, -1)
    @bridge.open_blocks = true
    session = short.new(bridge: @bridge)
    session.open(path: @skp)
    @bridge.define_singleton_method(:close) do |*_args|
      raise StandardError, 'close failed'
    end
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: false)
    session.status
    refute session.pending?
  end

  def test_in_call_wait_is_named
    assert_equal 15.0, DocumentSession::IN_CALL_WAIT_S
    assert_equal 30.0, DocumentSession::OPEN_DEADLINE_S
  end

  def test_new_document_refuses_a_dirty_untitled_leftover
    name_current(@skp, 'house')
    dirty = FakeDoc.new(path: nil, title: '', modified: true, entity_count: 3)
    @bridge.after_close = dirty
    result = @session.new_document
    refute result.ok
    assert_equal 'leftover_document', result.code
    assert_same dirty, @bridge.model
    refute_includes @bridge.actions, [:new]
  end

  def test_status_clears_leftover_after_extra_windows_are_gone
    @bridge.documents = 2
    first = @session.status
    refute first.ok
    assert_equal 'leftover_document', first.code
    @bridge.documents = 0
    later = @session.status
    assert later.ok
    assert_equal 'no_document', later.state
  end

  def test_status_clears_leftover_when_one_file_remains_focused
    @bridge.documents = 2
    first = @session.status
    refute first.ok
    assert_equal 'leftover_document', first.code

    leftover = FakeDoc.new(path: @skp, title: 'house')
    @bridge.model = leftover
    @bridge.documents = 1
    later = @session.status
    assert later.ok
    assert_equal 'active', later.state
    assert_equal @skp, later.snapshot.path
  end

  def test_revert_refuses_untitled
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: true)
    result = @session.revert
    refute result.ok
    assert_equal 'path_required', result.code
    assert_includes result.next, 'model_save'
    assert_includes result.next, 'if_unsaved=discard'
  end

  def test_save_rejects_unknown_mode_and_missing_paths
    name_current(@skp, 'house')
    unknown = @session.save(mode: 'nope')
    refute unknown.ok
    assert_equal 'unknown_arguments', unknown.code
    assert_includes unknown.next, 'in_place, save_as or copy'

    copy = @session.save(mode: 'copy')
    refute copy.ok
    assert_equal 'path_required', copy.code
    assert_includes copy.next, 'mode copy'

    save_as = @session.save(mode: 'save_as')
    refute save_as.ok
    assert_equal 'path_required', save_as.code
  end

  def test_close_refuses_when_the_snapshot_cannot_be_read
    leftover = Object.new
    def leftover.valid?
      false
    end
    @bridge.model = leftover
    result = @session.close
    refute result.ok
    assert_equal 'leftover_document', result.code
    assert_includes result.next, 'model_status'
    assert_same leftover, @bridge.model
  end

  def test_copy_version_error_does_not_point_at_a_path_retry
    name_current(@skp, 'house')
    @bridge.define_singleton_method(:save_copy) do |*_args, **_kwargs|
      raise ArgumentError, 'This host cannot write SketchUp 2017 copies.'
    end
    dest = File.join(@dir, 'copy.skp')
    result = @session.save(mode: 'copy', path: dest, version: 2017)
    refute result.ok
    assert_equal 'invalid_model_path', result.code
    assert_includes result.next, 'without version'
    refute_includes result.next, 'directory must exist'
  end

  def test_windows_open_closes_now_and_opens_on_the_next_tick
    @bridge.defer_open = true
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    name_current(@skp, 'house')
    @bridge.after_open = FakeDoc.new(path: other, title: 'other')

    first = @session.open(path: other)
    assert first.ok
    assert_equal 'opening', first.state
    assert_equal [[:close, true]], @bridge.actions
    assert @session.pending?

    @session.begin_tick
    second = @session.status
    assert_equal 'active', second.state
    assert_equal other, second.snapshot.path
    assert_equal 'opened', second.changed
    assert_equal [[:close, true], [:open, other]], @bridge.actions
  end

  def test_windows_revert_opens_on_the_next_tick
    @bridge.defer_open = true
    name_current(@skp, 'house')
    @bridge.model.modified = true
    @bridge.after_open = FakeDoc.new(path: @skp, title: 'house', modified: false)

    first = @session.revert
    assert first.ok
    assert_equal 'opening', first.state
    assert_equal [[:close, true]], @bridge.actions

    @session.begin_tick
    second = @session.status
    assert second.ok
    assert_equal 'active', second.state
    assert_equal 'reverted', second.changed
    assert_equal [[:close, true], [:open, @skp]], @bridge.actions
  end

  def test_windows_revert_does_not_accept_the_closing_file
    @bridge.defer_open = true
    name_current(@skp, 'house')
    @bridge.model.modified = true
    closing = @bridge.model
    @bridge.define_singleton_method(:close) do |_model, ignore_changes|
      @actions << [:close, ignore_changes]
    end

    first = @session.revert
    assert first.ok
    assert_equal 'opening', first.state
    refute first.reverted
    assert_same closing, @bridge.model
    assert_equal [[:close, true]], @bridge.actions
  end

  def test_windows_deferred_open_failure_does_not_claim_active
    @bridge.defer_open = true
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    name_current(@skp, 'house')
    first = @session.open(path: other)
    assert_equal 'opening', first.state

    @bridge.define_singleton_method(:open_path) do |_path|
      @actions << [:open_failed]
      raise StandardError, 'refused'
    end
    @session.begin_tick
    second = @session.status
    refute second.ok
    assert_equal 'model_open_failed', second.code
    refute_equal 'active', second.state
  end

  def test_windows_deferred_revert_failure_reports_model_revert_failed
    @bridge.defer_open = true
    name_current(@skp, 'house')
    @bridge.model.modified = true
    first = @session.revert
    assert_equal 'opening', first.state

    @bridge.define_singleton_method(:open_path) do |_path|
      @actions << [:open_failed]
      raise StandardError, 'refused'
    end
    @session.begin_tick
    second = @session.status
    refute second.ok
    assert_equal 'model_revert_failed', second.code
  end

  def test_windows_deferred_restore_open_failure_is_not_revert
    @bridge.defer_open = true
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    name_current(@skp, 'house')
    first = @session.open(path: other)
    assert_equal 'opening', first.state

    @bridge.define_singleton_method(:open_path) do |path|
      @actions << [:open, path]
      raise StandardError, 'refused'
    end
    @session.begin_tick
    second = @session.status
    refute second.ok
    assert_equal 'model_open_failed', second.code
    refute_equal 'model_revert_failed', second.code

    @session.begin_tick
    third = @session.status
    refute third.ok
    assert_equal 'model_open_failed', third.code
    refute_equal 'model_revert_failed', third.code
  end

  def test_unfocused_leftover_stays_when_document_count_becomes_unknown
    @bridge.documents = 2
    first = @session.status
    refute first.ok
    assert_equal 'leftover_document', first.code

    leftover = FakeDoc.new(path: @skp, title: 'house')
    @bridge.model = leftover
    @bridge.count_unknown = true
    later = @session.status
    refute later.ok
    assert_equal 'leftover_document', later.code
    refute_equal 'active', later.state
  end

  def test_save_rejects_an_existing_dest_whose_realpath_is_remote
    dest = File.join(@dir, 'out.skp')
    File.write(dest, 'x')
    @bridge.model = FakeDoc.new(path: nil, title: '', modified: true)
    @bridge.define_singleton_method(:realpath) do |path|
      text = path.to_s
      if File.file?(text) && File.basename(text) == 'out.skp'
        '//server/share/out.skp'
      elsif File.exist?(text)
        File.realpath(text)
      else
        File.expand_path(text)
      end
    end
    saved = @session.save(path: dest)
    refute saved.ok
    assert_equal 'invalid_model_path', saved.code
    assert_includes saved.message, 'network share'
  end

  def test_focused_leftover_clears_when_the_leftover_is_closed
    leftover = FakeDoc.new(path: @skp, title: 'house', modified: false)
    @bridge.model = leftover
    @bridge.define_singleton_method(:close) { |*_args| nil }
    first = @session.new_document
    refute first.ok
    assert_equal 'leftover_document', first.code

    @bridge.model = nil
    @bridge.documents = 0
    later = @session.status
    assert later.ok
    assert_equal 'no_document', later.state
  end

  def test_focused_leftover_clears_when_another_file_is_focused
    leftover = FakeDoc.new(path: @skp, title: 'house', modified: false, guid: 'leftover')
    @bridge.model = leftover
    @bridge.define_singleton_method(:close) { |*_args| nil }
    first = @session.new_document
    refute first.ok
    assert_equal 'leftover_document', first.code

    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    @bridge.model = FakeDoc.new(path: other, title: 'other', guid: 'other')
    @bridge.documents = 1
    later = @session.status
    assert later.ok
    assert_equal 'active', later.state
    assert_equal other, later.snapshot.path
  end

  def test_restore_becomes_active_when_the_previous_file_is_focused
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    name_current(other, 'other')
    requested = @skp
    @bridge.define_singleton_method(:open_path) do |path|
      @actions << [:open, path]
      raise StandardError, 'launch failed' if path == requested

      @model = FakeDoc.new(path: path, title: File.basename(path, '.skp'))
    end
    result = @session.open(path: requested)
    refute result.ok
    assert_equal 'model_open_failed', result.code
    assert @session.pending?

    recovered = @session.status
    assert recovered.ok
    assert_equal 'active', recovered.state
    assert_equal other, recovered.snapshot.path
    refute_equal 'model_revert_failed', recovered.code
  end

  def test_windows_deferred_restore_becomes_active
    @bridge.defer_open = true
    other = File.join(@dir, 'other.skp')
    TestSupport.write_skp(other)
    other = File.realpath(other)
    name_current(@skp, 'house')
    first = @session.open(path: other)
    assert_equal 'opening', first.state

    @bridge.define_singleton_method(:open_path) do |path|
      @actions << [:open, path]
      raise StandardError, 'refused' if path == other

      @model = FakeDoc.new(path: path, title: File.basename(path, '.skp'))
    end
    @session.begin_tick
    second = @session.status
    refute second.ok
    assert_equal 'model_open_failed', second.code
    assert @session.pending?

    @session.begin_tick
    third = @session.status
    assert third.ok
    assert_equal 'active', third.state
    assert_equal @skp, third.snapshot.path
    refute_equal 'model_revert_failed', third.code
  end
end
