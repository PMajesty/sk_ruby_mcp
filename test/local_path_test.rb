# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'

class LocalPathTest < Minitest::Test
  LocalPath = SkRubyMcp::Runtime::LocalPath
  PathProbe = SkRubyMcp::Runtime::PathProbe

  class Probe
    def initialize(remote_resolved: nil)
      @remote_resolved = remote_resolved
    end

    def remote?(path)
      text = path.to_s.tr('\\', '/')
      text.start_with?('//') || (!@remote_resolved.nil? && path == @remote_resolved)
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
  end

  def test_writable_file_rejects_an_existing_symlink_to_unc
    Dir.mktmpdir do |dir|
      dest = File.join(dir, 'out.json')
      File.write(dest, '{}')
      probe = Probe.new(remote_resolved: File.realpath(dest))
      def probe.realpath(path)
        File.file?(path.to_s) ? @remote_resolved : File.expand_path(path.to_s)
      end
      error = assert_raises(ArgumentError) { LocalPath.writable_file(dest, probe: probe) }
      assert_includes error.message, 'network share'
    end
  end

  def test_writable_file_accepts_a_new_file_in_a_local_directory
    Dir.mktmpdir do |dir|
      dest = File.join(dir, 'out.json')
      assert_equal dest, LocalPath.writable_file(dest, probe: PathProbe.new)
    end
  end

  def test_writable_file_accepts_an_existing_local_file
    Dir.mktmpdir do |dir|
      dest = File.join(dir, 'out.json')
      File.write(dest, '{}')
      assert_equal dest, LocalPath.writable_file(dest, probe: PathProbe.new)
    end
  end

  def test_camera_argument_requires_a_path_probe_for_camera_file
    error = assert_raises(ArgumentError) do
      SkRubyMcp::Tools::FacadePack::CameraArgument.resolve(nil, 'relative.json')
    end
    assert_includes error.message, 'absolute'
  end
end
