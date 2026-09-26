require 'libosctl'

module OsCtld
  # The same exit cleanup for console-managed and direct LXC starts.
  class Container::StopHandler
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::Exception

    def self.schedule(ct, run_conf = nil)
      thread = Thread.new { new(ct, run_conf).run }
      ThreadReaper.add(thread, nil)
    end

    attr_reader :ct

    def initialize(ct, run_conf = nil)
      @ct = ct
      @run_conf = run_conf
    end

    def run
      # The TTY may have closed due to an unforeseen error, check if the
      # container is actually stopped.
      60.times do
        break if ct.state == :stopped

        log(:info, ct, 'Exit handler waiting for stopped state')
        sleep(1)
      end

      unless ct.state == :stopped
        log(:fatal, ct, 'Exit handler ran, but container is not stopped')
        return
      end

      ctrc = @run_conf || ct.get_past_run_conf
      return if @run_conf && !ct.get_past_run_conf.equal?(@run_conf)
      return if ctrc && !ctrc.claim_exit_handling

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

      ct.forget_past_run_conf(ctrc)
    end

    protected

    def handle_improper_ct_stop
      # In this scenario, it is possible that the veth-down hooks weren't
      # run either. Use the same all-record preflight and durable taint gate as
      # forced deletion; never perform an unchecked direct teardown.
      Container::Recovery.new(ct).cleanup_or_taint
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
