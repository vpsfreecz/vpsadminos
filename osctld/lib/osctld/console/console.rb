require 'base64'
require 'osctld/console/tty'

module OsCtld
  # Special case for tty0 (/dev/console)
  #
  # tty0 is opened on container start, at least when it's started by osctld.
  # The tty is accessed using named pipes, one for writing to the tty, one for
  # reading from the tty. These pipes are provided using {#connect}.
  class Console::Console < Console::TTY
    def open
      # Does nothing for tty0, it is opened automatically on ct start
    end

    def connect(pid, input, output)
      sync do
        @opened = true
        self.tty_pid = pid
        self.tty_in_io = input
        self.tty_out_io = output
        wake
      end
    end
  end
end
