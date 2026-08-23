module OsCtld
  # Instance per container, each holding a list of opened ttys
  class Console::Container
    attr_reader :ct

    def initialize(ct)
      @ct = ct
      @ttys = {}
      @mutex = Mutex.new
      @closed = false
    end

    def add_client(tty_n, io)
      tty(tty_n).add_client(io)
    end

    def connect_tty0(
      pid,
      socket,
      run_conf,
      effect_id: nil,
      intent_id: nil,
      retry_timeout: nil
    )
      if effect_id || intent_id || retry_timeout
        tty(0).connect(
          pid,
          socket,
          run_conf,
          effect_id:,
          intent_id:,
          retry_timeout:
        )
      else
        tty(0).connect(pid, socket, run_conf)
      end
    end

    def tty(n)
      @mutex.synchronize do
        raise 'console container is closed' if @closed

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
        return if @closed

        @closed = true
        @ttys.each_value(&:close)
      end
    end

    protected

    def sync(&)
      @mutex.synchronize(&)
    end
  end
end
