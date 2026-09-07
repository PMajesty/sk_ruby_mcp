# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../packaging/zip_archive'

class ZipArchiveTest < Minitest::Test
  def test_roundtrip_text
    entries = write_and_read('readme.txt' => 'hello')
    assert_equal ['readme.txt'], entries.map(&:name)
    assert_equal 'hello', entries.first.data
  end

  def test_roundtrip_binary_and_empty
    payload = [0, 1, 255, 0].pack('C*')
    entries = write_and_read('empty.dat' => '', 'blob.bin' => payload)
    by_name = entries.map { |entry| [entry.name, entry.data] }.to_h
    assert_equal '', by_name['empty.dat']
    assert_equal payload, by_name['blob.bin']
  end

  def test_nested_paths_use_forward_slashes
    entries = write_and_read('sk_ruby_mcp/assets/blank.skp' => 'skp')
    assert_equal ['sk_ruby_mcp/assets/blank.skp'], entries.map(&:name)
  end

  def test_backslash_in_name_is_normalized
    archive = Packaging::ZipArchive.new
    archive.add('sk_ruby_mcp\\main.rb', 'x')
    assert_equal ['sk_ruby_mcp/main.rb'], archive.names
  end

  def test_incompressible_data_roundtrips
    data = Random.new(1).bytes(256)
    entries = write_and_read('rand.bin' => data)
    assert_equal data, entries.first.data
  end

  def test_rejects_absolute_and_parent_names
    archive = Packaging::ZipArchive.new
    assert_raises(ArgumentError) { archive.add('/tmp/x.rb', 'x') }
    assert_raises(ArgumentError) { archive.add('foo/../x.rb', 'x') }
    assert_raises(ArgumentError) { archive.add('', 'x') }
  end

  def test_rejects_duplicate_names
    archive = Packaging::ZipArchive.new
    archive.add('a.rb', '1')
    error = assert_raises(ArgumentError) { archive.add('a.rb', '2') }
    assert_includes error.message, 'duplicate'
  end

  def test_read_rejects_garbage
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'nope.zip')
      File.binwrite(path, 'not a zip')
      assert_raises(ArgumentError) { Packaging::ZipArchive.read(path) }
    end
  end

  def test_read_rejects_empty_archive_bytes
    assert_raises(ArgumentError) { Packaging::ZipArchive.parse('PK') }
  end

  private

  def write_and_read(files)
    archive = Packaging::ZipArchive.new
    files.each { |name, data| archive.add(name, data) }
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'out.zip')
      archive.write(path)
      Packaging::ZipArchive.read(path)
    end
  end
end
