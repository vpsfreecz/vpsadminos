require 'libosctl'

module OsCtld
  # Module holding functions and classes working with container consoles/ttys
  module Console
    include OsCtl::Lib::Utils::Log

    def self.init
      @mutex = Mutex.new
      @cts = {}
    end

    # Reserve exit cleanup for the wrapper even if its console cannot connect.
    def self.expect_tty0(ct)
      @mutex.synchronize { container(ct).expect_tty0(ct.run_conf) }
    end

    def self.handles_run?(ct, run_conf)
      @mutex.synchronize { @cts[container_key(ct)]&.handles_run?(run_conf) || false }
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
        container(ct).expect_tty0(ct.run_conf)

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
      key = container_key(ct)
      @cts[key] = Container.new(ct) unless @cts.has_key?(key)
      @cts[key]
    end

    # Remove {Console::Container} for `ct` and close all ttys
    def self.remove(ct)
      @mutex.synchronize do
        key = container_key(ct)
        next unless @cts.has_key?(key)

        @cts.delete(key).close_all
      end
    end

    # Return path of the socket to the container's tty0
    def self.socket_path(ct)
      File.join(ct.pool.console_dir, ct.id, 'tty0.sock')
    end

    def self.container_key(ct)
      [ct.pool.name, ct.id]
    end
    private_class_method :container_key
  end
end
