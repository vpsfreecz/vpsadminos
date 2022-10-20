require 'base64'
require 'libosctl'
require 'osctld/console/tty'

module OsCtld
  # Special case for tty0 (/dev/console)
  #
  # tty0 is opened on container start, at least when it's started by osctld.
  # The tty is accessed using unix server socket created by the osctld
  # container wrapper.
  class Console::Console < Console::TTY
    include OsCtl::Lib::Utils::Exception

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
      ctrc = ct.get_past_run_conf

      CpuScheduler.unschedule_ct(ct)

      begin
        ct.update_hints
      rescue Exception => e
        log(:warn, ct, "Unable to update hints: #{e.message} (#{e.class})")
        log(:warn, ct, denixstorify(e.backtrace))
      end

      if ctrc.nil?
        # This means that {UserControl::Commands::CtPostStop} hasn't run for some
        # reason.
        log(:fatal, ct, 'Unable to properly handle container stop')
        handle_improper_ct_stop
        return
      end

      if ctrc.aborted? \
         || ctrc.reboot? \
         || ct.lxcfs.running? \
         || (ct.ephemeral? && !ct.is_being_manipulated?) \
         || (ctrc && ctrc.destroy_dataset_on_stop?)
        # The current thread is used to handle the console and has to exit.
        # Manipulation must happen from another thread.
        t = Thread.new { handle_ct_stop(ctrc) }
        ThreadReaper.add(t, nil)
      end

      ct.forget_past_run_conf
    end

    def handle_improper_ct_stop
      # In this scenario, it is possible that the veth-down hooks weren't
      # run either. Cleanup interfaces that may have been left behind.
      ct.netifs.take_down
    end

    def handle_ct_stop(ctrc)
      if ctrc.aborted?
        log(:info, ctrc, 'Container was aborted, performing cleanup')
        recovery = Container::Recovery.new(ctrc.ct)
        recovery.cleanup_or_taint
      end

      if ctrc.destroy_dataset_on_stop?
        begin
          zfs(:destroy, nil, ctrc.dataset)
        rescue SystemCommandFailed => e
          log(:warn, ctrc, "Unable to destroy dataset '#{ctrc.dataset}': #{e.message}")
        end
      end

      if ctrc.reboot?
        sleep(1)
        reboot_ct

      elsif ctrc.aborted?
        return

      elsif ct.ephemeral? && !ct.is_being_manipulated?
        Commands::Container::Delete.run(
          pool: ct.pool.name,
          id: ct.id,
          force: true,
          manipulation_lock: 'wait',
        )

      elsif !ct.is_being_manipulated?
        ctrc.ct.lxcfs.ensure_stop
      end
    end

    def reboot_ct
      begin
        ret = Commands::Container::Start.run(
          pool: ct.pool.name,
          id: ct.id,
          force: true,
          manipulation_lock: 'wait',
        )
      rescue CommandFailed => e
        log(:warn, ct, "Reboot failed: #{e.message}")

      else
        if !ret.is_a?(Hash)
          log(:warn, ct, 'Reboot failed: reason unknown')
        elsif !ret[:status]
          log(:warn, ct, "Reboot failed: #{ret[:message]}")
        end
      end
    end
  end
end
