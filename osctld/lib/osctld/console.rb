require 'libosctl'

module OsCtld
  # Module holding functions and classes working with container consoles/ttys
  module Console
    include OsCtl::Lib::Utils::Log

    RECONNECT_TIMEOUT = 5

    def self.init
      @mutex = Mutex.new
      @cts = {}
    end

    # Connect to tty0 of container `ct`
    def self.connect_tty0(
      ct,
      pid,
      run_conf,
      effect_id: nil,
      intent_id: nil,
      retry_timeout: nil
    )
      console = container(ct)
      if effect_id || intent_id || retry_timeout
        console.connect_tty0(
          pid,
          socket_path(ct),
          run_conf,
          effect_id:,
          intent_id:,
          retry_timeout:
        )
      else
        console.connect_tty0(pid, socket_path(ct), run_conf)
      end
    end

    # Reconnect tty0 pipes on osctld restart
    def self.reconnect_tty0(ct, run_conf)
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

      container(ct).connect_tty0(
        nil,
        socket,
        run_conf,
        retry_timeout: RECONNECT_TIMEOUT
      )
      true
    rescue StandardError => e
      log(
        :warn,
        ct,
        "Unable to reopen TTY0, console will not work: #{e.message} " \
        "(#{e.class})"
      )
      false
    end

    # Add client socket `io` for container `ct` to tty `n`
    def self.client(ct, n, io)
      container(ct).add_client(n, io)
    end

    # Return {Console::Container} for `ct`
    def self.container(ct)
      @mutex.synchronize do
        key = container_key(ct)
        @cts[key] ||= Container.new(ct)
      end
    end

    # Remove {Console::Container} for `ct` and close all ttys
    def self.remove(ct)
      console = @mutex.synchronize do
        key = container_key(ct)
        @cts.delete(key)
      end
      console&.close_all
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
