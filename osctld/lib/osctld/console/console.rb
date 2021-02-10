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
        on_ct_stop
      end
    end

    def on_ct_stop
      if ct.reboot? \
         || (ct.ephemeral? && !ct.is_being_manipulated?)
        # The current thread is used to handle the console and has to exit.
        # Manipulation must happen from another thread.
        t = Thread.new { handle_ct_stop }
        ThreadReaper.add(t, nil)
      end
    end

    def handle_ct_stop
      if ct.reboot?
        sleep(1)
        reboot_ct

      elsif ct.ephemeral? && !ct.is_being_manipulated?
        Commands::Container::Delete.run({
          pool: ct.pool.name,
          id: ct.id,
          force: true,
          manipulation_lock: 'wait',
        })
      end
    end

    def reboot_ct
      ret = Commands::Container::Start.run({
        pool: ct.pool.name,
        id: ct.id,
        force: true,
        manipulation_lock: 'wait',
      })

      if !ret.is_a?(Hash)
        log(:warn, ct, 'Reboot failed: reason unknown')
      elsif !ret[:status]
        log(:warn, ct, "Reboot failed: #{ret[:message]}")
      end
    end
  end
end
