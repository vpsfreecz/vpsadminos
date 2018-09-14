require 'base64'
require 'osctld/console/tty'

module OsCtld
  # Special case for tty0 (/dev/console)
  #
  # tty0 is opened on container start, at least when it's started by osctld.
  # The tty is accessed using unix server socket created by the osctld
  # container wrapper.
  class Console::Console < Console::TTY
    def open
      # Does nothing for tty0, it is opened automatically on ct start
    end

    def connect(pid, socket)
      tries = 0

      begin
        c = UNIXSocket.new(socket)

      rescue Errno::ENOENT
        raise if tries >= (0.2 * 50 * 10) # try for 10 seconds
        tries += 1
        sleep(0.2)
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
  end
end
