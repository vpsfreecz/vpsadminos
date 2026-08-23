require 'libosctl'
require 'osctld/cgroup'
require 'timeout'

module OsCtld
  class Hook::Base
    class << self
      attr_reader :hook_name, :user_hook_name

      # Register hook under a name
      # @param event_class [Class]
      # @param hook_name [Symbol]
      def hook(event_class, hook_name, hook_class)
        @hook_name = hook_name
        @user_hook_name = hook_name.to_s.gsub('_', '-')
        Hook.register(event_class, hook_name, hook_class)
      end

      # Mark the hook as blocking or async, defaults to async
      # @param v [Boolean] `true` for blocking, `false` for async
      def blocking(v)
        @blocking = v
      end

      def blocking?
        @blocking || false
      end
    end

    include OsCtl::Lib::Utils::Log

    # @return [Class]
    attr_reader :event_instance

    def initialize(event_instance, opts)
      @event_instance = event_instance
      @opts = opts
      setup
    end

    def setup; end

    # Execute the user script hook.
    #
    # For blocking hooks, this method waits for the script hook to exit. If it
    # exits with non-zero exit status, exception {HookFailed} is raised. Async
    # hooks return immediately and their exit status has no meaning.
    #
    # @param hook_path [String]
    def exec(hook_path)
      log(
        :info,
        event_instance,
        "Executing hook #{self.class.hook_name} at #{hook_path}"
      )

      env = environment
      lifecycle_owner = lifecycle_process_owner
      gate_r, gate_w = IO.pipe if lifecycle_owner

      if lifecycle_owner
        run = lifecycle_owner.fetch(:lifecycle).run(
          lifecycle_owner.fetch(:run_id)
        )
        cgroup_path = run&.dig('resources', 'host_effects')
        raise HookFailed.new(self, hook_path, 1) unless cgroup_path

        lifecycle_owner[:cgroup_path] = cgroup_path
      end

      pid = Process.fork do
        Process.setsid
        gate_w&.close
        if gate_r
          authorized = gate_r.gets&.strip == 'ready'
          gate_r.close
          exit(false) unless authorized
        end

        ENV.delete_if { |k, _| k != 'PATH' }
        env.each { |k, v| ENV[k] = v }

        Process.exec(*executable(hook_path))
      end

      if lifecycle_owner
        gate_r.close
        begin
          process_id = lifecycle_owner.fetch(:lifecycle).register_process(
            lifecycle_owner.fetch(:run_id),
            kind: "hook:#{self.class.hook_name}",
            pid:
          )
          raise 'container lifecycle changed before hook exec' unless process_id

          lifecycle_owner[:process_id] = process_id
          CGroup.mkpath_all(
            lifecycle_owner.fetch(:cgroup_path).split('/')
          )
          CGroup.attach_to_all(
            lifecycle_owner.fetch(:cgroup_path).split('/'),
            pid:
          )
          gate_w.puts('ready')
        rescue StandardError
          gate_w.close
          Process.wait(pid)
          finish_lifecycle_process(lifecycle_owner)
          raise
        ensure
          gate_w.close unless gate_w.closed?
        end
      end

      if blocking?
        _, status = wait_for_blocking_hook(pid, hook_path)
        finish_lifecycle_process(lifecycle_owner)
        return true if status.exitstatus == 0

        log(
          :warn,
          event_instance,
          "Hook #{self.class.hook_name} at #{hook_path} exited with #{status.exitstatus}"
        )

        raise HookFailed.new(self, hook_path, status.exitstatus)

      else
        Hook.watch(self, hook_path, pid, lifecycle_owner:)
      end
    ensure
      if blocking? && lifecycle_owner && lifecycle_owner[:process_id]
        finish_lifecycle_process(lifecycle_owner)
      end
    end

    def blocking?
      self.class.blocking?
    end

    protected

    # @return [Hash]
    attr_reader :opts

    def lifecycle_process_owner
      return unless event_instance.respond_to?(:lifecycle)
      return unless event_instance.respond_to?(:run_conf)
      return unless event_instance.respond_to?(:get_past_run_conf)

      run_conf = event_instance.run_conf || event_instance.get_past_run_conf
      return unless run_conf

      {
        lifecycle: event_instance.lifecycle,
        run_id: run_conf.run_id
      }
    end

    def wait_for_blocking_hook(pid, hook_path)
      timeout = opts[:timeout]
      return Process.wait2(pid) unless timeout

      Timeout.timeout(timeout) { Process.wait2(pid) }
    rescue Timeout::Error
      terminate_hook_process_group(pid)
      raise HookFailed.new(self, hook_path, 124)
    end

    def terminate_hook_process_group(pid)
      signal_hook_process_group(pid, 'TERM')
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      waited = nil
      loop do
        waited ||= Process.waitpid2(pid, Process::WNOHANG)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(0.05)
      end
      # The leader can exit while descendants remain in its process group.
      # Always kill the group after the grace period, then reap the leader if
      # it was still alive.
      signal_hook_process_group(pid, 'KILL')
      waited || Process.wait2(pid)
    rescue Errno::ECHILD
      waited
    end

    def signal_hook_process_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      begin
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end
    end

    def finish_lifecycle_process(owner)
      return unless owner && owner[:process_id]

      process_id = owner.delete(:process_id)
      effect_id = owner.fetch(:lifecycle).finish_process(
        owner.fetch(:run_id),
        process_id
      )
      return unless effect_id

      run_conf = [
        event_instance.run_conf,
        event_instance.get_past_run_conf
      ].compact.detect { |conf| conf.run_id == owner.fetch(:run_id) }
      return unless run_conf

      require 'osctld/container/lifecycle_finalizer'
      Container::LifecycleFinalizer.spawn(
        event_instance,
        run_conf,
        effect_id
      )
    end

    # Override this method to define environment variables that the script hook
    # will have set.
    # @return [Hash<String, String>]
    def environment
      {
        'OSCTL_HOOK_NAME' => self.class.user_hook_name
      }
    end

    # Override this method to define the program and its arguments that will be
    # execed to invoke the user script hook.
    # @param hook_path [String]
    # @return [Array<String>]
    def executable(hook_path)
      [hook_path]
    end
  end
end
