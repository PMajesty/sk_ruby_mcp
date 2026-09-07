# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative '../packaging/rbz_bundler'

class RbzBundlerTest < Minitest::Test
  REPO = File.expand_path('..', __dir__)
  CLI = File.join(REPO, 'bin', 'sk-mcp-bundle')

  def test_default_output_path_uses_version
    Dir.mktmpdir do |dir|
      write_plugin(dir, version: '9.8.7')
      dest = Packaging::RbzBundler.new(root: dir).default_output_path
      assert_equal File.join(dir, 'dist', 'sk_ruby_mcp-9.8.7.rbz'), dest
    end
  end

  def test_payload_is_registrar_plus_support_files
    Dir.mktmpdir do |dir|
      write_plugin(dir)
      names = Packaging::RbzBundler.new(root: dir).payload_names
      assert_equal [
        'sk_ruby_mcp.rb',
        'sk_ruby_mcp/assets/blank.skp',
        'sk_ruby_mcp/main.rb',
        'sk_ruby_mcp/version.rb'
      ], names.sort
      roots = names.map { |name| name.split('/', 2).first }.uniq.sort
      assert_equal ['sk_ruby_mcp', 'sk_ruby_mcp.rb'], roots
    end
  end

  def test_payload_skips_finder_and_editor_junk
    Dir.mktmpdir do |dir|
      write_plugin(dir)
      File.write(File.join(dir, 'sk_ruby_mcp', '.DS_Store'), 'mac')
      File.write(File.join(dir, 'sk_ruby_mcp', 'Thumbs.db'), 'win')
      File.write(File.join(dir, 'sk_ruby_mcp', 'main.rb~'), 'bak')
      FileUtils.mkdir_p(File.join(dir, 'sk_ruby_mcp', 'nested'))
      File.write(File.join(dir, 'sk_ruby_mcp', 'nested', '.DS_Store'), 'mac')
      names = Packaging::RbzBundler.new(root: dir).payload_names
      refute_includes names, 'sk_ruby_mcp/.DS_Store'
      refute_includes names, 'sk_ruby_mcp/Thumbs.db'
      refute_includes names, 'sk_ruby_mcp/main.rb~'
      refute_includes names, 'sk_ruby_mcp/nested/.DS_Store'
    end
  end

  def test_write_roundtrips_blank_and_registrar
    Dir.mktmpdir do |dir|
      write_plugin(dir, blank: "skp\0bytes")
      dest = File.join(dir, 'out.rbz')
      written = Packaging::RbzBundler.new(root: dir).write(dest)
      assert_equal dest, written
      entries = Packaging::ZipArchive.read(dest)
      by_name = entries.map { |entry| [entry.name, entry.data] }.to_h
      assert_equal "skp\0bytes", by_name['sk_ruby_mcp/assets/blank.skp']
      assert_includes by_name['sk_ruby_mcp.rb'], 'SketchupExtension'
    end
  end

  def test_write_rejects_non_rbz_extension
    Dir.mktmpdir do |dir|
      write_plugin(dir)
      error = assert_raises(ArgumentError) do
        Packaging::RbzBundler.new(root: dir).write(File.join(dir, 'out.zip'))
      end
      assert_includes error.message, '.rbz'
    end
  end

  def test_missing_required_files_raise
    %w[sk_ruby_mcp.rb sk_ruby_mcp/main.rb sk_ruby_mcp/version.rb sk_ruby_mcp/assets/blank.skp].each do |relative|
      Dir.mktmpdir do |dir|
        write_plugin(dir)
        FileUtils.rm_f(File.join(dir, relative))
        FileUtils.rm_rf(File.join(dir, relative)) if relative == 'sk_ruby_mcp/assets/blank.skp'
        error = assert_raises(ArgumentError) { Packaging::RbzBundler.new(root: dir).payload_names }
        assert_includes error.message, relative
      end
    end
  end

  def test_version_reads_utf8_comments_when_default_external_is_us_ascii
    previous = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    Dir.mktmpdir do |dir|
      write_plugin(dir, version_source: "# \xC2\xA9\nmodule SkRubyMcp\n  VERSION = '1.2.3'\nend\n")
      assert_equal '1.2.3', Packaging::RbzBundler.new(root: dir).version
    end
  ensure
    Encoding.default_external = previous
  end

  def test_version_missing_constant_raises
    Dir.mktmpdir do |dir|
      write_plugin(dir, version_source: "module SkRubyMcp\nend\n")
      error = assert_raises(ArgumentError) { Packaging::RbzBundler.new(root: dir).version }
      assert_includes error.message, 'VERSION'
    end
  end

  def test_repo_archive_is_plugin_only
    bundler = Packaging::RbzBundler.new(root: REPO)
    names = bundler.payload_names
    expected = repo_plugin_files
    assert_equal expected, names.sort
    names.each do |name|
      refute_match(%r{\A(test|eval|bin|packaging)/}, name)
      refute_equal 'README.md', name
    end
    roots = names.map { |name| name.split('/', 2).first }.uniq.sort
    assert_equal ['sk_ruby_mcp', 'sk_ruby_mcp.rb'], roots
    assert_includes names, 'sk_ruby_mcp/assets/blank.skp'
    assert_includes names, 'sk_ruby_mcp/main.rb'
  end

  def test_cli_writes_the_given_rbz_and_prints_its_path
    Dir.mktmpdir do |dir|
      dest = File.join(dir, 'plugin.rbz')
      stdout = IO.popen([RbConfig.ruby, CLI, '-o', dest], err: [:child, :out], &:read)
      assert_equal 0, $?.exitstatus, stdout
      assert_equal dest, stdout.strip
      names = Packaging::ZipArchive.read(dest).map(&:name)
      assert_includes names, 'sk_ruby_mcp.rb'
      assert_includes names, 'sk_ruby_mcp/assets/blank.skp'
    end
  end

  def test_cli_writes_default_dist_rbz
    dest = Packaging::RbzBundler.new(root: REPO).default_output_path
    FileUtils.rm_f(dest)
    stdout = IO.popen([RbConfig.ruby, CLI], err: [:child, :out], &:read)
    assert_equal 0, $?.exitstatus, stdout
    assert_equal dest, stdout.strip
    assert File.file?(dest), dest
    names = Packaging::ZipArchive.read(dest).map(&:name)
    assert_includes names, 'sk_ruby_mcp.rb'
    assert_includes names, 'sk_ruby_mcp/assets/blank.skp'
  ensure
    FileUtils.rm_f(dest) if dest
  end

  def test_cli_packaging_error_prints_the_error_not_usage
    Dir.mktmpdir do |dir|
      dest = File.join(dir, 'out.zip')
      stdout = IO.popen([RbConfig.ruby, CLI, '-o', dest], err: [:child, :out], &:read)
      assert_equal 2, $?.exitstatus, stdout
      assert_includes stdout, '.rbz'
      refute_includes stdout, 'usage:'
    end
  end

  def test_cli_usage_on_bad_args
    stdout = IO.popen([RbConfig.ruby, CLI, '--nope'], err: [:child, :out], &:read)
    assert_equal 2, $?.exitstatus
    assert_includes stdout, 'usage:'
  end

  private

  def repo_plugin_files
    names = ['sk_ruby_mcp.rb']
    support = File.join(REPO, 'sk_ruby_mcp')
    Dir.glob(File.join(support, '**', '*'), File::FNM_DOTMATCH).each do |abs|
      next unless File.file?(abs)

      rel = abs.delete_prefix(support + File::SEPARATOR).tr('\\', '/')
      next if rel.split('/').any? { |part| part.start_with?('.') }

      names << File.join('sk_ruby_mcp', rel)
    end
    names.sort
  end

  def write_plugin(dir, version: '1.0.0', version_source: nil, blank: 'BLANK')
    support = File.join(dir, 'sk_ruby_mcp')
    FileUtils.mkdir_p(File.join(support, 'assets'))
    File.write(File.join(dir, 'sk_ruby_mcp.rb'), "SketchupExtension.new('SK Ruby MCP', 'sk_ruby_mcp/main')\n")
    File.write(File.join(support, 'main.rb'), "module SkRubyMcp\nend\n")
    File.write(
      File.join(support, 'version.rb'),
      version_source || "module SkRubyMcp\n  VERSION = '#{version}'\nend\n"
    )
    File.binwrite(File.join(support, 'assets', 'blank.skp'), blank)
  end
end
