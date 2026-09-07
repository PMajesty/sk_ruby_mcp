# frozen_string_literal: true

# Собирает установщик SketchUp: корневой registrar и одноимённая папка поддержки.

require 'fileutils'
require_relative 'zip_archive'

module Packaging
  class RbzBundler
    EXTENSION_ID = 'sk_ruby_mcp'
    REGISTRAR = "#{EXTENSION_ID}.rb"
    SUPPORT = EXTENSION_ID
    MAIN = File.join(SUPPORT, 'main.rb')
    VERSION_FILE = File.join(SUPPORT, 'version.rb')
    BLANK = File.join(SUPPORT, 'assets', 'blank.skp')
    REQUIRED = [REGISTRAR, MAIN, VERSION_FILE, BLANK].freeze

    def initialize(root:)
      @root = File.expand_path(root)
    end

    def version
      text = File.read(absolute(VERSION_FILE), encoding: Encoding::UTF_8)
      match = text.match(/\bVERSION\s*=\s*['"]([^'"]+)['"]/)
      raise ArgumentError, "VERSION missing in #{VERSION_FILE}" if match.nil? || match[1].strip.empty?

      match[1]
    end

    def default_output_path
      File.join(@root, 'dist', "#{EXTENSION_ID}-#{version}.rbz")
    end

    def payload_paths
      validate_required!
      [[REGISTRAR, absolute(REGISTRAR)]] + support_files
    end

    def payload_names
      payload_paths.map(&:first)
    end

    def write(path = nil)
      dest = File.expand_path(path || default_output_path)
      unless File.extname(dest).downcase == '.rbz'
        raise ArgumentError, 'output path must end with .rbz'
      end

      archive = ZipArchive.new
      payload_paths.each do |name, abs|
        archive.add(name, File.binread(abs))
      end
      FileUtils.mkdir_p(File.dirname(dest))
      archive.write(dest)
      dest
    end

    private

    def validate_required!
      REQUIRED.each do |relative|
        abs = absolute(relative)
        next if File.file?(abs)

        raise ArgumentError, "missing #{relative} in #{@root}"
      end
    end

    def support_files
      support_root = absolute(SUPPORT)
      raise ArgumentError, "missing #{SUPPORT} in #{@root}" unless File.directory?(support_root)

      files = []
      Dir.glob(File.join(support_root, '**', '*'), File::FNM_DOTMATCH).sort.each do |abs|
        next unless File.file?(abs)

        relative = rel_from(support_root, abs)
        next if skip_relative?(relative)

        files << [File.join(SUPPORT, relative), abs]
      end
      files
    end

    def skip_relative?(relative)
      relative.split('/').any? { |part| junk_name?(part) }
    end

    def junk_name?(name)
      name.empty? || name.start_with?('.') || name == 'Thumbs.db' || name.end_with?('~')
    end

    def absolute(relative)
      File.join(@root, relative)
    end

    def rel_from(root, abs)
      prefix = root.end_with?('/', '\\') ? root : root + File::SEPARATOR
      abs.delete_prefix(prefix).tr('\\', '/')
    end
  end
end
