# frozen_string_literal: true

# Guards that raise when code reaches a process, a network socket or a libvips loader. They cannot be
# uninstalled (Ruby has no unprepend), so they are only ever installed inside a child Ruby process
# started by the test that needs them; the parent test process never sees them. Violations raise an
# Exception subclass (not a StandardError, so a stray +rescue => e+ cannot swallow one) and are also
# recorded in Guards.violations.
module Guards
  class Violation < Exception; end # rubocop:disable Lint/InheritException

  @violations = []

  class << self
    attr_reader :violations

    def trip(what)
      @violations << what
      raise Violation, "forbidden call: #{what}"
    end

    # Subprocess guards (parsing-and-safety.md 9.2): Kernel instance and singleton methods, Process,
    # IO.popen and every singleton method of Open3.
    def install_process_guards!
      require "open3"

      kernel_names = %i[system spawn exec fork ` open]
      guard = Module.new do
        kernel_names.each do |name|
          define_method(name) { |*_args, **_kw, &_block| Guards.trip("Kernel##{name}") }
          private name
        end
      end
      Kernel.prepend(guard)
      Kernel.singleton_class.prepend(singleton_guard("Kernel", kernel_names))
      Process.singleton_class.prepend(singleton_guard("Process", %i[spawn fork exec daemon]))
      IO.singleton_class.prepend(singleton_guard("IO", %i[popen]))
      Open3.singleton_class.prepend(singleton_guard("Open3", Open3.singleton_methods))
    end

    # Loader guards: Vips::Image.new_from_* plus Vips::Operation.call, the one Ruby entry into every
    # libvips operation (ruby-vips dispatches pngload, *load_buffer, thumbnail and the rest through
    # method_missing, so they are not real singleton methods). Any loader or thumbnail operation trips.
    def install_loader_guards!
      names = %i[new_from_buffer new_from_file new_from_source]
      names |= Vips::Image.singleton_methods.select { |name| name.to_s.include?("load") }
      Vips::Image.singleton_class.prepend(singleton_guard("Vips::Image", names))
      Vips::Operation.singleton_class.prepend(Module.new do
        define_method(:call) do |name, *args, **kw, &block|
          Guards.trip("Vips::Operation.call(#{name})") if name.to_s.match?(/load|thumbnail/i)
          super(name, *args, **kw, &block)
        end
      end)
    end

    # Network guards: socket class methods and Socket#connect, plus name resolution.
    def install_network_guards!
      require "socket"

      [TCPSocket, UDPSocket, Socket].each do |klass|
        klass.singleton_class.prepend(singleton_guard(klass.name, %i[new open tcp udp_server_sockets
                                                                    getaddrinfo gethostbyname]))
      end
      Socket.prepend(Module.new do
        %i[connect connect_nonblock bind].each { |name| define_method(name) { |*_a| Guards.trip("Socket##{name}") } }
      end)
      Addrinfo.singleton_class.prepend(singleton_guard("Addrinfo", %i[getaddrinfo tcp udp ip foreach]))
    end

    private

    def singleton_guard(label, names)
      Module.new do
        names.each do |name|
          define_method(name) { |*_args, **_kw, &_block| Guards.trip("#{label}.#{name}") }
        end
      end
    end
  end
end
