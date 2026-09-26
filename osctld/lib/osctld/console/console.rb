require 'base64'
require 'libosctl'
require 'osctld/console/tty'
require 'osctld/container/stop_handler'

module OsCtld
  # Special case for tty0 (/dev/console)
  #
  # tty0 is opened on container start, at least when it's started by osctld.
  # The tty is accessed using unix server socket created by the osctld
  # container wrapper.
  class Console::Console < Console::TTY
    include OsCtl::Lib::Utils::Exception

    CONNECT_RETRY_ERRORS = [Errno::ENOENT, Errno::ECONNREFUSED].freeze
    CONNECT_RETRY_LIMIT = 100
    CONNECT_RETRY_INTERVAL = 0.2

    def open
      # Does nothing for tty0, it is opened automatically on ct start
    end

    def expect_run(run_conf)
      sync { @run_conf = run_conf }
    end

    def handles_run?(run_conf)
      sync { run_conf && @run_conf.equal?(run_conf) }
    end

    def connect(pid, socket)
      expect_run(ct.run_conf)
      tries = 0

      begin
        c = UNIXSocket.new(socket)
      rescue *CONNECT_RETRY_ERRORS
        raise if tries >= CONNECT_RETRY_LIMIT

        tries += 1
        sleep(CONNECT_RETRY_INTERVAL)
        retry
      end

      sync do
        @opened = true
        self.tty_pid = pid
        self.tty_in_io = c
        self.tty_out_io = c
        wake
      end
    end

    protected

    def on_close
      # The current thread is used to handle the console and has to exit.
      # Manipulation must happen from another thread.
      Container::StopHandler.schedule(ct, @run_conf)
    end
  end
end
