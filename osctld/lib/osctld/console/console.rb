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

    protected
    def on_close
      if ct.state == :stopped
        if ct.reboot?
          t = Thread.new do
            Commands::Container::Start.run({
              pool: ct.pool.name,
              id: ct.id,
              force: true,
              manipulation_lock: 'wait',
            })
          end

          ThreadReaper.add(t, nil)

        elsif ct.ephemeral? && !ct.is_being_manipulated?
          # The container deletion has to be invoked from another thread, because
          # the current thread is used to handle the console and has to exit when
          # the container is being deleted.
          t = Thread.new do
            Commands::Container::Delete.run({
              pool: ct.pool.name,
              id: ct.id,
              force: true,
              manipulation_lock: 'wait',
            })
          end

          ThreadReaper.add(t, nil)
        end
      end
    end
  end
end
