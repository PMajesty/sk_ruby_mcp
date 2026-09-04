# frozen_string_literal: true

module SkRubyMcp
  module Transport
    # Сопоставление метода и пути с обработчиком: 404 для чужих путей, 405 для чужих методов.
    class Router
      def initialize
        @routes = {}
      end

      def add(method, path, handler)
        (@routes[path] ||= {})[method] = handler
        self
      end

      def call(request)
        handlers = @routes[request.path]
        return HttpResponse.json(404, { error: "Not found: #{request.path}" }) unless handlers

        handler = handlers[request.method]
        return HttpResponse.empty(405, headers: { 'Allow' => handlers.keys.join(', ') }) unless handler

        handler.call(request)
      end
    end
  end
end
