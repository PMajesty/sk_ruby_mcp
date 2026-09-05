# frozen_string_literal: true

require 'fiddle'

module SkRubyMcp
  module Runtime
    # AppKit: число документов и активация окна. Нельзя брать модель из ObjectSpace:
    # геометрия на ней роняет SketchUp 2022. Тик не качает run loop.
    module MacosAppKit
      module_function

      def document_count
        controller = msg0(cls('NSDocumentController'), sel('sharedDocumentController'))
        documents = msg0(controller, sel('documents'))
        integer(msg0(documents, sel('count')))
      rescue StandardError
        nil
      end

      def activate_app
        app = nsapp
        if responds?(app, 'activateIgnoringOtherApps:')
          msg_bool(app, sel('activateIgnoringOtherApps:'), 1)
        elsif responds?(app, 'activate')
          msg0(app, sel('activate'))
        end
        make_document_key(app)
      rescue StandardError
        nil
      end

      def nsapp
        msg0(cls('NSApplication'), sel('sharedApplication'))
      end

      def make_document_key(app)
        windows = msg0(app, sel('windows'))
        count = integer(msg0(windows, sel('count')))
        index = 0
        while index < count
          window = msg_index(windows, sel('objectAtIndex:'), index)
          class_name = utf8(msg0(msg0(window, sel('class')), sel('description')))
          if class_name == 'SketchUpWindow'
            msg1(window, sel('makeKeyAndOrderFront:'), Fiddle::Pointer.new(0))
            return
          end
          index += 1
        end
      end

      def libobjc
        @libobjc ||= Fiddle.dlopen('/usr/lib/libobjc.A.dylib')
      end

      def cls(name)
        get_class.call(name)
      end

      def sel(name)
        register_sel.call(name)
      end

      def get_class
        @get_class ||= Fiddle::Function.new(libobjc['objc_getClass'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      end

      def register_sel
        @register_sel ||= Fiddle::Function.new(libobjc['sel_registerName'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      end

      def msg0(receiver, selector)
        msg0_fn.call(receiver, selector)
      end

      def msg1(receiver, selector, argument)
        msg1_fn.call(receiver, selector, argument)
      end

      def msg_index(receiver, selector, index)
        msg_index_fn.call(receiver, selector, index)
      end

      def msg_bool(receiver, selector, value)
        msg_bool_fn.call(receiver, selector, value)
      end

      def msg0_fn
        @msg0_fn ||= Fiddle::Function.new(
          libobjc['objc_msgSend'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_VOIDP
        )
      end

      def msg1_fn
        @msg1_fn ||= Fiddle::Function.new(
          libobjc['objc_msgSend'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
          Fiddle::TYPE_VOIDP
        )
      end

      def msg_index_fn
        @msg_index_fn ||= Fiddle::Function.new(
          libobjc['objc_msgSend'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
          Fiddle::TYPE_VOIDP
        )
      end

      def msg_bool_fn
        @msg_bool_fn ||= Fiddle::Function.new(
          libobjc['objc_msgSend'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_CHAR],
          Fiddle::TYPE_VOIDP
        )
      end

      def responds?(object, selector_name)
        integer(msg1(object, sel('respondsToSelector:'), sel(selector_name))) != 0
      end

      def integer(value)
        value.to_i
      end

      def utf8(object)
        return nil if object.nil? || object.to_i.zero?

        pointer = msg0(object, sel('UTF8String'))
        return nil if pointer.nil? || pointer.to_i.zero?

        Fiddle::Pointer.new(pointer.to_i).to_s
      end
    end

    # Мост к SketchUp и AppKit. Тесты подставляют фейк с тем же интерфейсом.
    class SketchupAttachBridge
      ACTIVATE_BEFORE_VERSION = 25.0

      def current_model
        model = Sketchup.active_model
        model if model && model.valid?
      end

      def file_new
        Sketchup.file_new
      rescue StandardError
        nil
      end

      def document_count
        return current_model ? 1 : 0 unless macos?

        MacosAppKit.document_count
      end

      def needs_activation?
        macos? && Sketchup.version.to_f < ACTIVATE_BEFORE_VERSION
      end

      def activate_app
        return unless macos?

        Log.info('activating SketchUp so the new document becomes active_model')
        MacosAppKit.activate_app
      end

      def peek_active_model
        current_model
      end

      def create_blank
        file_new
        activate_app if needs_activation?
        peek_active_model
      end

      def macos?
        Sketchup.platform == :platform_osx
      rescue StandardError
        false
      end
    end
  end
end
