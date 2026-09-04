# frozen_string_literal: true

require 'socket'

module SkRubyMcp
  # Платформенно-зависимая настройка сокетов.
  # SO_REUSEADDR для слушающего сокета не выставляем сами: TCPServer делает это на macOS,
  # а на Windows эта опция разрешила бы двум процессам занять один порт.
  module Platform
    class << self
      # Отключаем алгоритм Нейгла: ответы маленькие, задержка важнее объёма.
      def configure_client_socket(socket)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      rescue SystemCallError, IOError
        nil
      end
    end
  end
end
