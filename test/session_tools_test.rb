# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'schema_check'
require 'tmpdir'
require 'fileutils'

class SessionToolsTest < Minitest::Test
  SessionResult = SkRubyMcp::Runtime::SessionResult
  ModelSnapshot = SkRubyMcp::Runtime::ModelSnapshot

  class OpeningThenActive
    def initialize(active)
      @active = active
      @n = 0
    end

    def open(*)
      opening
    end

    def status(*)
      @n += 1
      @n >= 3 ? @active : opening
    end

    def opening
      SessionResult.new(ok: true, state: 'opening', snapshot: nil)
    end
  end

  class FakeSession
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def status
      @calls << :status
      @result
    end

    def open(path:, if_unsaved: nil)
      @calls << [:open, path, if_unsaved]
      @result
    end

    def new_document(if_unsaved: nil)
      @calls << [:new, if_unsaved]
      @result
    end

    def save(mode: 'in_place', path: nil, version: nil)
      @calls << [:save, mode, path, version]
      @result
    end

    def close(if_unsaved: nil)
      @calls << [:close, if_unsaved]
      @result
    end

    def revert
      @calls << :revert
      @result
    end
  end

  def active_result
    SessionResult.new(
      ok: true,
      state: 'active',
      next: 'Use execute_ruby',
      snapshot: ModelSnapshot.new(
        path: '/tmp/house.skp', title: 'house', modified: false,
        faces: 6, units: 'm', root_entities: 3, selection: 0, edit_context: 'root'
      )
    )
  end

  def parsed(result)
    JSON.parse(result[:content].first[:text])
  end

  def test_model_status_annotations_and_wait_s
    spec = SkRubyMcp::Tools::ModelStatus.new(session: FakeSession.new(active_result)).spec
    assert_equal 'model_status', spec[:name]
    assert_equal false, spec[:annotations][:readOnlyHint]
    assert_equal false, spec[:annotations][:destructiveHint]
    assert_equal true, spec[:annotations][:idempotentHint]
    assert spec.key?(:outputSchema)
    assert_includes spec[:description], 'wait_s=15'
  end

  def test_model_new_description_warns_against_a_second_call
    text = SkRubyMcp::Tools::ModelNew.new(session: FakeSession.new(active_result)).spec[:description]
    assert_includes text, 'Never call model_new twice'
    assert_includes text, 'if_unsaved'
  end

  def test_model_status_renders_structured_json
    tool = SkRubyMcp::Tools::ModelStatus.new(session: FakeSession.new(active_result))
    result = tool.call({})
    refute result[:isError]
    body = parsed(result)
    assert_equal true, body['ok']
    assert_equal 'active', body['state']
    assert_equal 'house', body['title']
    assert_equal result[:structuredContent], body
  end

  def test_model_status_calls_session_status
    session = FakeSession.new(active_result)
    SkRubyMcp::Tools::ModelStatus.new(session: session).call('wait_s' => 15)
    assert_equal [:status], session.calls
  end

  def test_model_save_passes_mode
    session = FakeSession.new(active_result)
    SkRubyMcp::Tools::ModelSave.new(session: session).call('path' => '/tmp/copy.skp', 'mode' => 'copy')
    assert_equal [[:save, 'copy', '/tmp/copy.skp', nil]], session.calls
  end

  def test_unknown_arguments_are_rejected
    tool = SkRubyMcp::Tools::ModelStatus.new(session: FakeSession.new(active_result))
    result = tool.call('extra' => 1)
    assert result[:isError]
    assert_equal 'unknown_arguments', parsed(result)['error']
  end

  def test_model_open_requires_path_and_passes_if_unsaved
    session = FakeSession.new(active_result)
    tool = SkRubyMcp::Tools::ModelOpen.new(session: session)
    missing = tool.call({})
    assert missing[:isError]
    assert_equal 'path_required', parsed(missing)['error']
    assert_includes parsed(missing)['next'], 'model_open'
    refute parsed(missing).key?('instead')
    assert_empty session.calls

    tool.call('path' => '/tmp/a.skp', 'if_unsaved' => 'discard')
    assert_equal [[:open, '/tmp/a.skp', 'discard']], session.calls
  end

  def test_model_revert_is_its_own_tool
    session = FakeSession.new(active_result)
    spec = SkRubyMcp::Tools::ModelRevert.new(session: session).spec
    assert_equal 'model_revert', spec[:name]
    assert_equal true, spec[:annotations][:destructiveHint]
    assert_equal false, spec[:annotations][:idempotentHint]
    SkRubyMcp::Tools::ModelRevert.new(session: session).call({})
    assert_equal [:revert], session.calls
  end

  def test_model_close_passes_if_unsaved
    session = FakeSession.new(active_result)
    SkRubyMcp::Tools::ModelClose.new(session: session).call('if_unsaved' => 'discard')
    assert_equal [[:close, 'discard']], session.calls
  end

  def test_document_reply_matches_output_schema
    tool = SkRubyMcp::Tools::ModelStatus.new(session: FakeSession.new(active_result))
    result = tool.call({})
    assert SchemaCheck.valid?(SkRubyMcp::Tools::DOCUMENT_OUTPUT_SCHEMA, result[:structuredContent])
  end

  def test_model_new_defers_while_opening
    opening = SessionResult.new(ok: true, state: 'opening', snapshot: nil)
    result = SkRubyMcp::Tools::ModelNew.new(session: FakeSession.new(opening)).call({})
    assert_instance_of SkRubyMcp::Runtime::Deferred, result
  end

  def test_model_open_defers_while_opening
    opening = SessionResult.new(ok: true, state: 'opening', snapshot: nil, next: 'Call model_status with wait_s=15 until state is active.')
    result = SkRubyMcp::Tools::ModelOpen.new(session: FakeSession.new(opening)).call('path' => '/tmp/a.skp')
    assert_instance_of SkRubyMcp::Runtime::Deferred, result
    still = result.resolve
    assert_nil still
  end

  def test_model_open_deferred_resolves_opened_on_later_status
    session = OpeningThenActive.new(active_result.tap { |item| item.changed = 'opened' })
    deferred = SkRubyMcp::Tools::ModelOpen.new(session: session).call('path' => '/tmp/a.skp')
    assert_instance_of SkRubyMcp::Runtime::Deferred, deferred
    assert_nil deferred.resolve
    assert_nil deferred.resolve
    done = deferred.resolve
    refute_nil done
    body = JSON.parse(done[:content].first[:text])
    assert_equal 'active', body['state']
    assert_equal 'opened', body['changed']
  end

  def test_model_status_wait_s_defers_opening
    session = OpeningThenActive.new(active_result)
    result = SkRubyMcp::Tools::ModelStatus.new(session: session).call('wait_s' => 15)
    assert_instance_of SkRubyMcp::Runtime::Deferred, result
    assert_nil result.resolve
    done = result.resolve
    refute_nil done
    assert_equal 'active', JSON.parse(done[:content].first[:text])['state']
  end

  def test_model_status_without_wait_does_not_defer_opening
    opening = SessionResult.new(ok: true, state: 'opening', snapshot: nil)
    result = SkRubyMcp::Tools::ModelStatus.new(session: FakeSession.new(opening)).call({})
    refute_instance_of SkRubyMcp::Runtime::Deferred, result
    assert_equal 'opening', parsed(result)['state']
  end

  def test_session_tool_rescue_names_status
    exploding = Object.new
    def exploding.status(*)
      raise RuntimeError, 'status boom'
    end
    status_text = SkRubyMcp::Tools::ModelStatus.new(session: exploding).call({})[:content].first[:text]
    assert_includes status_text, 'status boom'
    assert_includes status_text, 'model_status'
  end

  def test_untitled_reply_keeps_null_path
    untitled = SessionResult.new(
      ok: true,
      state: 'active',
      snapshot: ModelSnapshot.new(path: nil, title: '', modified: false, faces: 0)
    )
    body = parsed(SkRubyMcp::Tools::ModelStatus.new(session: FakeSession.new(untitled)).call({}))
    assert body.key?('path')
    assert_nil body['path']
    assert_equal 'Untitled', body['title']
    assert SchemaCheck.valid?(SkRubyMcp::Tools::DOCUMENT_OUTPUT_SCHEMA, body)
  end

  def test_noop_and_path_requested_and_save_as_and_copy
    same = SessionResult.new(
      ok: true,
      state: 'active',
      already_open: true,
      snapshot: ModelSnapshot.new(path: '/tmp/house.skp', title: 'house', modified: false)
    )
    body = parsed(SkRubyMcp::Tools::ModelOpen.new(session: FakeSession.new(same)).call('path' => '/tmp/house.skp'))
    assert_equal 'noop', body['changed']

    requested = SessionResult.new(
      ok: true,
      state: 'active',
      requested_path: '/tmp/Alias.skp',
      snapshot: ModelSnapshot.new(path: '/tmp/house.skp', title: 'house', modified: false)
    )
    requested_body = parsed(SkRubyMcp::Tools::ModelOpen.new(session: FakeSession.new(requested)).call('path' => '/tmp/Alias.skp'))
    refute_equal requested_body['path'], requested_body['path_requested']
    assert_includes requested_body['path_requested'], 'Alias.skp'

    saved_as = SessionResult.new(
      ok: true,
      state: 'active',
      saved_as: true,
      snapshot: ModelSnapshot.new(path: '/tmp/named.skp', title: 'named', modified: false)
    )
    assert_equal 'saved_as', parsed(SkRubyMcp::Tools::ModelSave.new(session: FakeSession.new(saved_as)).call('mode' => 'save_as', 'path' => '/tmp/named.skp'))['changed']

    copied = SessionResult.new(
      ok: true,
      state: 'active',
      copied: true,
      copy_path: '/tmp/copy.skp',
      snapshot: ModelSnapshot.new(path: '/tmp/house.skp', title: 'house', modified: false)
    )
    copy_body = parsed(SkRubyMcp::Tools::ModelSave.new(session: FakeSession.new(copied)).call('mode' => 'copy', 'path' => '/tmp/copy.skp'))
    assert_equal 'copied', copy_body['changed']
    assert_includes copy_body['copy_path'], 'copy.skp'
    assert SchemaCheck.valid?(SkRubyMcp::Tools::DOCUMENT_OUTPUT_SCHEMA, copy_body)

    reverted = SessionResult.new(
      ok: true,
      state: 'active',
      reverted: true,
      snapshot: ModelSnapshot.new(path: '/tmp/house.skp', title: 'house', modified: false)
    )
    assert_equal 'reverted', parsed(SkRubyMcp::Tools::ModelRevert.new(session: FakeSession.new(reverted)).call({}))['changed']
  end

  def test_error_opening_and_temporary_match_output_schema
    failed = SessionResult.new(ok: false, state: 'failed', code: 'no_document', message: 'No focused document.', next: 'Call model_new.')
    failed_body = parsed(SkRubyMcp::Tools::ModelStatus.new(session: FakeSession.new(failed)).call({}))
    assert SchemaCheck.valid?(SkRubyMcp::Tools::DOCUMENT_OUTPUT_SCHEMA, failed_body)

    opening = SessionResult.new(ok: true, state: 'opening', next: 'Call model_status with wait_s=15 until state is active.')
    opening_body = parsed(SkRubyMcp::Tools::ModelStatus.new(session: FakeSession.new(opening)).call({}))
    assert_equal 'opening', opening_body['state']
    assert SchemaCheck.valid?(SkRubyMcp::Tools::DOCUMENT_OUTPUT_SCHEMA, opening_body)

    temporary = SessionResult.new(
      ok: true,
      state: 'active',
      temporary: true,
      snapshot: ModelSnapshot.new(path: '/tmp/scratch.skp', title: 'scratch', modified: false)
    )
    temp_body = parsed(SkRubyMcp::Tools::ModelNew.new(session: FakeSession.new(temporary)).call({}))
    assert_equal true, temp_body['temporary']
    assert SchemaCheck.valid?(SkRubyMcp::Tools::DOCUMENT_OUTPUT_SCHEMA, temp_body)
  end

  def test_wait_s_accepts_integer_valued_floats_and_rejects_the_rest
    session = OpeningThenActive.new(active_result)
    deferred = SkRubyMcp::Tools::ModelStatus.new(session: session).call('wait_s' => 15.0)
    assert_instance_of SkRubyMcp::Runtime::Deferred, deferred

    bad = SkRubyMcp::Tools::ModelStatus.new(session: FakeSession.new(active_result)).call('wait_s' => 1.5)
    assert bad[:isError]
    assert_equal 'invalid_wait_s', parsed(bad)['error']

    text = SkRubyMcp::Tools::ModelStatus.new(session: FakeSession.new(active_result)).call('wait_s' => '15')
    assert text[:isError]
    assert_equal 'invalid_wait_s', parsed(text)['error']
  end

  def test_garbage_if_unsaved_is_rejected
    session = FakeSession.new(active_result)
    result = SkRubyMcp::Tools::ModelClose.new(session: session).call('if_unsaved' => 'yes')
    assert result[:isError]
    assert_equal 'unknown_arguments', parsed(result)['error']
    assert_empty session.calls
  end

  def test_model_revert_defers_while_opening
    opening = SessionResult.new(ok: true, state: 'opening', snapshot: nil)
    result = SkRubyMcp::Tools::ModelRevert.new(session: FakeSession.new(opening)).call({})
    assert_instance_of SkRubyMcp::Runtime::Deferred, result
  end

  def test_model_revert_deferred_resolves_reverted_on_later_status
    session = OpeningThenActive.new(active_result.tap { |item| item.changed = 'reverted' })
    def session.revert
      opening
    end
    deferred = SkRubyMcp::Tools::ModelRevert.new(session: session).call({})
    assert_instance_of SkRubyMcp::Runtime::Deferred, deferred
    assert_nil deferred.resolve
    assert_nil deferred.resolve
    done = deferred.resolve
    refute_nil done
    body = JSON.parse(done[:content].first[:text])
    assert_equal 'active', body['state']
    assert_equal 'reverted', body['changed']
  end
end
