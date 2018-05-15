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

    # Connect i/o named pipes with tty0 to container `ct`
    def self.connect_tty0(ct, pid, input, output)
      @mutex.synchronize do
        container(ct).connect_tty0(pid, input, output)
      end
    end

    # Reconnect tty0 pipes on osctld restart
    def self.reconnect_tty0(ct)
      @mutex.synchronize do
        log(:info, ct, "Reopening TTY0")
        i, o = tty0_pipes(ct)

        [i, o].each do |path|
          next if File.exist?(path)
          log(
            :warn,
            ct,
            "Pipe '#{path}' for tty0 not found, console will not work"
          )
          return
        end

        container(ct).connect_tty0(
          nil,
          File.open(i, 'w'),
          File.open(o, 'r')
        )
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
      @cts[ct.id] = Container.new(ct) if !@cts.has_key?(ct.id)
      @cts[ct.id]
    end

    # Remove {Console::Container} for `ct` and close all ttys
    def self.remove(ct)
      @mutex.synchronize do
        next unless @cts.has_key?(ct.id)

        @cts.delete(ct.id).close_all
      end
    end

    # Return paths for pipes of container `ctid` for tty0 input/output
    def self.tty0_pipes(ct)
      base = ct.pool.console_dir

      [
        File.join(base, "#{ct.id}.in"),
        File.join(base, "#{ct.id}.out"),
      ]
    end
  end
end
