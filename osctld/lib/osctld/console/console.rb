require 'base64'
require 'libosctl'
require 'osctld/console/tty'

module OsCtld
  # Special case for tty0 (/dev/console)
  #
  # tty0 is opened on container start, at least when it's started by osctld.
  # The tty is accessed using a unix server socket passed to the osctld
  # container wrapper.
  class Console::Console < Console::TTY
    include OsCtl::Lib::Utils::Exception

    CONNECT_RETRY_ERRORS = [Errno::ENOENT, Errno::ECONNREFUSED].freeze
    CONNECT_RETRY_LIMIT = 100
    CONNECT_RETRY_INTERVAL = 0.2
    STOP_HANDLER_RETRY_INTERVAL = 0.1
    STOP_HANDLER_RETRY_MAX_INTERVAL = 5

    def open
      # Does nothing for tty0, it is opened automatically on ct start
    end

    def connect(pid, socket, run_conf, retry_limit: CONNECT_RETRY_LIMIT)
      tries = 0
      c = nil

      begin
        c = UNIXSocket.new(socket)
      rescue *CONNECT_RETRY_ERRORS
        raise if tries >= retry_limit

        tries += 1
        sleep(CONNECT_RETRY_INTERVAL)
        retry
      end

      attach(pid, c, run_conf)
    rescue StandardError
      c&.close unless c&.closed?
      raise
    end

    def attach(pid, io, run_conf, ready: true)
      sync do
        @opened = ready
        @run_conf = run_conf
        self.tty_pid = pid
        self.tty_in_io = ready ? io : nil
        self.tty_out_io = io
        wake
      rescue StandardError
        @opened = false
        @run_conf = nil
        self.tty_pid = nil
        self.tty_in_io = nil
        self.tty_out_io = nil
        raise
      end
    end

    def activate(run_conf)
      sync do
        return false unless @run_conf.equal?(run_conf) && tty_out_io

        @opened = true
        self.tty_in_io = tty_out_io
        wake
        true
      end
    end

    # Handle wrapper exit when the console socket could not be connected
    def wrapper_exited(run_conf)
      start_stop_handler(run_conf)
    end

    protected

    def on_close(run_conf)
      start_stop_handler(run_conf)
    end

    def close_context
      @run_conf.tap { @run_conf = nil }
    end

    def start_stop_handler(run_conf = nil)
      # The current thread is used to handle the console and has to exit.
      # Manipulation must happen from another thread.
      delay = STOP_HANDLER_RETRY_INTERVAL

      begin
        t = Thread.new { on_ct_stop(run_conf) }
      rescue ThreadError => e
        if Daemon.get.stopping?
          log(
            :info,
            ct,
            'osctld is shutting down, leaving stop cleanup for the next daemon'
          )
          return
        end

        log(:warn, ct, "Unable to create stop handler, retrying: #{e.message}")
        sleep(delay)
        delay = [delay * 2, STOP_HANDLER_RETRY_MAX_INTERVAL].min
        retry
      end

      ThreadReaper.add(t, nil)
    end

    def on_ct_stop(run_conf = nil)
      # The TTY may have closed due to an unforeseen error, check if the
      # container is actually stopped.
      60.times do
        break if ct.state == :stopped

        log(:info, ct, 'Console closed, waiting for stopped state')
        sleep(1)
      end

      unless ct.state == :stopped
        log(:fatal, ct, 'Console closed, but container is not stopped')
        return
      end

      ctrc = run_conf || ct.get_past_run_conf || ct.get_pending_run_conf

      if ctrc
        unless ct.stop_run(ctrc)
          log(:warn, ct, "Ignoring stop of stale run #{ctrc.run_id}")
          return
        end

        return unless ctrc.claim_exit_cleanup
      end

      CpuScheduler.unschedule_ct(ct)

      begin
        ct.update_hints
      rescue Exception => e # rubocop:disable Lint/RescueException
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

      start_failed = ctrc.start_pending? && ctrc.runtime_launching?

      # Send events about halt/reboot from the inside
      if !ctrc.aborted? && !ct.is_being_manipulated?
        Eventd.report(
          :ct_exit,
          pool: ct.pool.name,
          id: ct.id,
          exit_type: ctrc.reboot? ? 'reboot' : 'halt'
        )
      end

      handle_ct_stop(ctrc)

      return unless start_failed

      Eventd.report(
        :ct_start_failed,
        pool: ct.pool.name,
        id: ct.id,
        run_id: ctrc.run_id.to_s,
        message: 'container wrapper exited before the runtime started'
      )
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

      if !ct.ephemeral? && !ctrc.destroy_dataset_on_stop? && Daemon.get.config.writeout_dirtied_pages?
        # Force write-out of dirtied pages
        force_mount = false

        begin
          ct.unmount(force: true)
        rescue SystemCommandFailed => e
          log(:warn, ctrc, "Unable to unmount dataset for writeback: #{e.message}")
          force_mount = true
        end

        ct.mount(force: force_mount)
      end

      if ctrc.destroy_dataset_on_stop?
        GarbageCollector.free_container_run_dataset(ctrc, ctrc.dataset)
      end

      ctrc.fulfil_exit
      ct.forget_past_run_conf(ctrc)

      if ctrc.reboot?
        sleep(1)
        reboot_ct

      elsif ctrc.aborted?
        nil

      elsif ct.ephemeral? && !ct.is_being_manipulated?
        Commands::Container::Delete.run(
          pool: ct.pool.name,
          id: ct.id,
          force: true,
          manipulation_lock: 'wait'
        )
      end
    end

    def reboot_ct
      ct.pool.request_reboot(ct)

      until ct.pool.imported?
        log(:info, ct, 'Waiting for pool import to reboot')
        sleep(1)
      end

      begin
        ret = Commands::Container::Start.run(
          pool: ct.pool.name,
          id: ct.id,
          manipulation_lock: 'wait'
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
