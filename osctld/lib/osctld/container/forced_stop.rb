require 'libosctl'
require 'osctld/container/recovery'
require 'osctld/container_control/commands/state'

module OsCtld
  # One budget for a forced stop, including its fallback and verification.
  # Created before graceful shutdown, but its clock starts only on escalation.
  class Container::ForcedStop
    include OsCtl::Lib::Utils::Log

    TIMEOUT = 60
    RECOVERY_TIME = 10
    CANCELLATION_HEAD_START = 5

    def initialize(ct, run_conf: ct.get_run_conf)
      @ct = ct
      @run_conf = run_conf
      @started_at = nil
    end

    def started?
      !@started_at.nil?
    end

    # Only LXC runs outside the daemon. Recovery owns parent state and passes
    # the same absolute deadline to its external commands.
    def run(stop:)
      @started_at ||= now
      Lockable.with_deadline(deadline) { execute(stop) }
    end

    # Failure reporting uses the same acquisition budget, including after expiry.
    def taint
      Lockable.with_deadline(deadline) { @ct.state = :error }
    rescue OsCtld::DeadlockDetected => e
      log(:warn, "Unable to mark failed stop: #{e.message}")
    end

    def execute(stop)
      prepare

      begin
        result = stop.call(normal_deadline)
        return true if result.ok? && wait_stopped(normal_deadline)
      rescue StandardError => e
        log(:warn, "LXC stop failed: #{e.message}")
      end

      log(:warn, 'Killing container processes and recovering state')
      recovery = Container::Recovery.new(@ct, deadline:)
      recovery.kill_all
      thaw
      unless wait_stopped(deadline)
        raise ContainerControl::Error, 'container did not stop within the forced-stop timeout'
      end

      recovery.recover_state(state: :stopped)
      unless recovery.cleanup_or_taint
        raise ContainerControl::Error, 'unable to clean up stopped container'
      end

      true
    rescue StandardError => e
      taint
      raise ContainerControl::Error, "Unable to finish forced stop: #{e.message}"
    ensure
      thaw
    end

    private :execute

    # Time available for console/writeback completion after process teardown.
    def time_left
      [deadline - now, 0].max
    end

    def log_type
      "force-stop=#{@ct.ident}"
    end

    protected

    def prepare
      return if @prepared

      @prepared = true
      thaw
      begin
        head_start = [deadline, now + CANCELLATION_HEAD_START].min
        Lockable.with_deadline(head_start) do
          @run_conf.nfs_cancellation.capture(@run_conf.init_pid, deadline: head_start)
          @run_conf.nfs_cancellation.abort(wait: [head_start - now, 0].max, deadline: head_start)
        end
      rescue StandardError => e
        # Cancellation can fail even when the kernel advertises the control.
        # An explicit kill still has to reach LXC and direct recovery.
        log(:warn, "NFS cancellation failed before killing: #{e.message}")
      end
    end

    def thaw
      CGroup.thaw_tree(@ct.cgroup_path)
    rescue StandardError => e
      log(:warn, "Unable to thaw container: #{e.message}")
    end

    def wait_stopped(limit)
      while now < limit
        state = ContainerControl::Commands::State.run!(@ct, deadline: limit)
        return true if state.state == :stopped && cgroups_empty?

        sleep((limit - now).clamp(0, 0.1))
      end
      false
    rescue ContainerControl::Error => e
      log(:warn, "Unable to verify container termination: #{e.message}")
      false
    end

    def cgroups_empty?
      CGroup.subsystems.all? do |subsystem|
        path = CGroup.abs_cgroup_path(subsystem, @ct.cgroup_path)
        Dir.glob(File.join(path, '**/cgroup.procs')).all? do |file|
          File.read(file).strip.empty?
        rescue Errno::ENOENT
          true
        end
      end
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def deadline
      @started_at + TIMEOUT
    end

    def normal_deadline
      deadline - RECOVERY_TIME
    end
  end
end
