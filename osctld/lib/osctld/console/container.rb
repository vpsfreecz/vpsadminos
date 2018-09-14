require 'thread'

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

    def tty(n)
      @mutex.synchronize do
        if !@ttys.has_key?(n)
          klass = n == 0 ? Console::Console : Console::TTY
          @ttys[n] = tty = klass.new(ct, n)
          tty.start
          tty

        else
          @ttys[n]
        end
      end
    end

    def close_all
      @mutex.synchronize do
        @ttys.each { |_n, tty| tty.close }
      end
    end

    protected
    def sync
      @mutex.synchronize { yield }
    end
  end
end
