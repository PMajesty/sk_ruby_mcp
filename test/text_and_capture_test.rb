# frozen_string_literal: true

require_relative 'test_helper'

class TextTrimmerTest < Minitest::Test
  TextTrimmer = SkRubyMcp::TextTrimmer

  def test_binary_input_becomes_valid_utf8
    result = TextTrimmer.utf8("ok \xFF\xFE bytes".b)
    assert_equal Encoding::UTF_8, result.encoding
    assert result.valid_encoding?
    assert_includes result, 'ok'
  end

  def test_invalid_utf8_is_scrubbed
    result = TextTrimmer.utf8("caf\xC3".dup.force_encoding(Encoding::UTF_8))
    assert result.valid_encoding?
    assert_includes result, "\uFFFD"
  end

  def test_foreign_encoding_is_transcoded
    latin = "na\xEFve".dup.force_encoding(Encoding::ISO_8859_1)
    result = TextTrimmer.utf8(latin)
    assert_equal Encoding::UTF_8, result.encoding
    assert result.valid_encoding?
  end

  def test_short_text_is_not_truncated
    text, truncated = TextTrimmer.truncate('hello', 100)
    assert_equal 'hello', text
    refute truncated
  end

  def test_long_text_keeps_head_and_tail_with_marker
    original = ('A' * 500) + ('Z' * 500)
    text, truncated = TextTrimmer.truncate(original, 100)
    assert truncated
    assert text.start_with?('AAAA')
    assert text.end_with?('ZZZZ')
    assert_includes text, '[truncated: 900 bytes omitted]'
    assert_operator text.bytesize, :<, original.bytesize
  end

  def test_truncation_never_leaves_broken_multibyte_characters
    text, = TextTrimmer.truncate('я' * 400, 101)
    assert text.valid_encoding?
  end
end

class LogTest < Minitest::Test
  def test_info_stays_in_the_ring_and_does_not_print
    previous = SkRubyMcp::Log.sink
    sink = StringIO.new
    SkRubyMcp::Log.sink = sink
    SkRubyMcp::Log.info('quiet')
    SkRubyMcp::Log.error('loud')
    refute_includes sink.string, 'quiet'
    assert_includes sink.string, 'loud'
    assert SkRubyMcp::Log.entries.any? { |_time, level, message| level == :info && message == 'quiet' }
  ensure
    SkRubyMcp::Log.sink = previous
  end

  # Sketchup::Console makes puts private and only exposes write.
  class WriteOnlyConsole
    attr_reader :text

    def initialize
      @text = +''
    end

    def write(chunk)
      @text << chunk
      chunk.bytesize
    end

    private

    def puts(*)
      raise NoMethodError, 'private method puts'
    end
  end

  def test_errors_and_emit_reach_a_write_only_console
    previous = SkRubyMcp::Log.sink
    console = WriteOnlyConsole.new
    SkRubyMcp::Log.sink = console
    SkRubyMcp::Log.error('boom')
    SkRubyMcp::Log.emit('status line')
    SkRubyMcp::Log.emit("already terminated\n")
    assert_equal "[SkRubyMcp] ERROR: boom\nstatus line\nalready terminated\n", console.text
  ensure
    SkRubyMcp::Log.sink = previous
  end
end

class OutputCaptureTest < Minitest::Test
  OutputCapture = SkRubyMcp::Runtime::OutputCapture

  def test_puts_print_and_p_are_captured
    capture = OutputCapture.new(1024)
    capture.puts 'line'
    capture.print 'a', 'b'
    capture << 'c'
    capture.printf('%d!', 7)
    assert_equal "line\nabc7!", capture.string
    refute capture.truncated?
  end

  def test_output_beyond_limit_is_dropped_and_counted
    capture = OutputCapture.new(10)
    capture.write('12345')
    capture.write('67890ABCDE')
    capture.write('more')
    assert_equal '1234567890', capture.string
    assert capture.truncated?
    assert_equal 9, capture.dropped_bytes
  end

  def test_binary_writes_are_stored_as_valid_utf8
    capture = OutputCapture.new(1024)
    capture.write("bad \xFF byte".b)
    assert capture.string.valid_encoding?
    assert_equal Encoding::UTF_8, capture.string.encoding
  end

  def test_write_reports_bytes_written_like_an_io
    capture = OutputCapture.new(1024)
    assert_equal 5, capture.write('hello')
  end
end
