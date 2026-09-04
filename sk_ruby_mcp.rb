# frozen_string_literal: true

# Регистрация расширения. Вся логика находится в sk_ruby_mcp/main.rb и загружается SketchUp
# только если расширение включено в Extension Manager.

require 'sketchup.rb'
require 'extensions.rb'

Sketchup.require(File.join(__dir__, 'sk_ruby_mcp', 'version'))

module SkRubyMcp
  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new(EXTENSION_NAME, File.join(__dir__, 'sk_ruby_mcp', 'main'))
    extension.description = 'MCP server inside SketchUp with a single tool that executes Ruby on the main thread.'
    extension.version = VERSION
    extension.creator = 'Artyom Yurkov'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
