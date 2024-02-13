require 'libosctl'
require 'thread'

module OsCtld
  # Module holding functions and classes working with container consoles/ttys
  module Console
    include OsCtl::Lib::Utils::Log

    def self.init
      @mutex = Mutex.new
      @cts = {}
    end

    # Connect to tty0 of container `ct`
    def self.connect_tty0(ct, pid)
      @mutex.synchronize do
        container(ct).connect_tty0(pid, socket_path(ct))
      end
    end

    # Reconnect tty0 pipes on osctld restart
    def self.reconnect_tty0(ct)
      @mutex.synchronize do
        log(:info, ct, 'Reopening TTY0')

        socket = socket_path(ct)

        unless File.exist?(socket)
          log(
            :warn,
            ct,
            "Socket '#{socket}' for tty0 not found, console will not work"
          )
          return
        end

        container(ct).connect_tty0(nil, socket)
      end
    end

    # Add client socket `io` for container `ct` to tty `n`
    def self.client(ct, n, io)
      @mutex.synchronize do
        container(ct).add_client(n, io)
      end
    end

    # Return {Console::Container} for `ct`
    def self.container(ct)
      @cts[ct.id] = Container.new(ct) unless @cts.has_key?(ct.id)
      @cts[ct.id]
    end

    # Remove {Console::Container} for `ct` and close all ttys
    def self.remove(ct)
      @mutex.synchronize do
        next unless @cts.has_key?(ct.id)

        @cts.delete(ct.id).close_all
      end
    end

    # Return path of the socket to the container's tty0
    def self.socket_path(ct)
      File.join(ct.pool.console_dir, ct.id, 'tty0.sock')
    end
  end
end
