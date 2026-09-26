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

    def connect_tty0(pid, socket)
      tty(0).connect(pid, socket)
    end

    def expect_tty0(run_conf)
      @mutex.synchronize { @expected_run_conf = run_conf }
    end

    def handles_run?(run_conf)
      @mutex.synchronize do
        next false unless run_conf

        @expected_run_conf.equal?(run_conf) || @ttys[0]&.handles_run?(run_conf) || false
      end
    end

    def tty(n)
      @mutex.synchronize do
        if @ttys.has_key?(n)
          @ttys[n]
        else
          klass = n == 0 ? Console::Console : Console::TTY
          @ttys[n] = tty = klass.new(ct, n)
          tty.start
          tty

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
