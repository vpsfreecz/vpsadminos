module OsCtld
  # Instance per container, each holding a list of opened ttys
  class Console::Container
    attr_reader :ct

    def initialize(ct)
      @ct = ct
      @ttys = {}
      @mutex = Mutex.new
    end

    def add_client(tty_n, io)
      tty(tty_n).add_client(io)
    end

    def connect_tty0(pid, socket, run_conf)
      tty(0).connect(pid, socket, run_conf)
    end

    def attach_tty0(pid, io, run_conf, ready: true)
      tty(0).attach(pid, io, run_conf, ready:)
    end

    def activate_tty0(run_conf)
      tty(0).activate(run_conf)
    end

    def reconnect_tty0(socket, run_conf)
      tty(0).connect(nil, socket, run_conf, retry_limit: 0)
    end

    def tty(n)
      @mutex.synchronize do
        if @ttys.has_key?(n)
          @ttys[n]
        else
          klass = n == 0 ? Console::Console : Console::TTY
          tty = klass.new(ct, n)
          begin
            tty.start
          rescue StandardError
            tty.close
            raise
          end
          @ttys[n] = tty

        end
      end
    end

    def close_all
      @mutex.synchronize do
        @ttys.each_value(&:close)
      end
    end

    protected

    def sync(&)
      @mutex.synchronize(&)
    end
  end
end
