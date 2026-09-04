# frozen_string_literal: true

require 'socket'

module SkRubyMcp
  # Платформенные различия в одном месте: определение ОС и настройка сокетов.
  # SO_REUSEADDR для слушающего сокета не выставляем сами: TCPServer делает это на macOS,
  # а на Windows эта опция разрешила бы двум процессам занять один порт.
  module Platform
    class << self
      def mac?
        return Sketchup.platform == :platform_osx if sketchup_platform_available?

        RUBY_PLATFORM.include?('darwin')
      end

      def windows?
        return Sketchup.platform == :platform_win if sketchup_platform_available?

        RUBY_PLATFORM.match?(/mswin|mingw|cygwin/)
      end

      # Отключаем алгоритм Нейгла: ответы маленькие, задержка важнее объёма.
      def configure_client_socket(socket)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      rescue SystemCallError, IOError
        nil
      end

      private

      def sketchup_platform_available?
        defined?(Sketchup) && Sketchup.respond_to?(:platform)
      end
    end
  end
end
