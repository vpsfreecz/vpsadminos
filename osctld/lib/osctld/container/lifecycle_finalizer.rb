require 'osctld/container/recovery'
require 'osctld/eventd'
require 'osctld/hook'
require 'osctld/thread_reaper'

module OsCtld
  # Executes post-stop effects for an exact lifecycle generation.
  class Container::LifecycleFinalizer
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::Exception

    WRAPPER_CHECK_INTERVAL = 0.2

    def self.spawn(ct, run_conf, effect_id)
      thread = Thread.new { new(ct, run_conf, effect_id).execute }
      ThreadReaper.add(thread, nil, group: :durable_lifecycle)
      thread
    end

    def self.watch_wrapper(ct, run_conf, child_pid: nil)
      thread = Thread.new do
        if child_pid
          begin
            Process.wait(child_pid)
          rescue Errno::ECHILD
            nil
          end
        end

        loop do
          run = ct.lifecycle.run(run_conf.run_id)
          break unless run

          managers = %w[wrapper lxc_start].filter_map do |name|
            cfg = run[name]
            cfg && ProcessIdentity.load(cfg)
          end
          managers.concat(
            Array(run['legacy_managers']).map do |cfg|
              ProcessIdentity.load(cfg)
            end
          )
          break unless managers.any?(&:alive?)
          break if Daemon.get.stopping?

          sleep(WRAPPER_CHECK_INTERVAL)
        end

        unless Daemon.get.stopping?
          effect_id = ct.lifecycle.observe_wrapper_gone(run_conf.run_id)
          if effect_id
            spawn(ct, run_conf, effect_id)
          elsif ct.lifecycle.active_run_id == run_conf.run_id \
              && !ct.lifecycle.run(run_conf.run_id)&.fetch('post_stop', false)
            begin
              Container::Recovery.new(ct).recover_state(run_id: run_conf.run_id)
            rescue ArgumentError, CommandFailed, Container::Recovery::Busy
              # The active generation changed or recovery fenced reconciliation
              # after the exact-run check, or restart admission closed after
              # the stable wrapper stopped.
            end
          end
        end
      rescue StandardError => e
        log_watcher_failure('wrapper', ct, run_conf, e)
      end
      ThreadReaper.add(thread, nil, group: :durable_lifecycle)
      thread
    end

    # Reconstruct liveness after daemon restart when a persisted callback or
    # hook process still owns the generation. There is deliberately no
    # deadline: once the last exact identity exits, state recovery atomically
    # prunes its lease, supersedes stale effects and reclaims finalization.
    def self.watch_reconciliation(ct, run_conf, recovery_key: nil)
      thread = Thread.new do
        resolved = false
        loop do
          break if Daemon.get.stopping?

          run = ct.lifecycle.run(run_conf.run_id)
          unless run && ct.lifecycle.active_run_id == run_conf.run_id
            resolved = true
            break
          end
          break if run['recovery']

          begin
            Container::Recovery.new(ct).recover_state(run_id: run_conf.run_id)
            resolved = true
            break
          rescue Container::Recovery::Busy
            sleep(WRAPPER_CHECK_INTERVAL)
          rescue ArgumentError
            resolved = true
            break
          end
        end
        if resolved && recovery_key
          Daemon.get.clear_recovery_failure(recovery_key)
        end
      rescue CommandFailed
        # Restart preparation closed recovery admission. The persisted run is
        # sufficient for the replacement daemon to resume reconciliation.
      rescue StandardError => e
        log_watcher_failure('reconciliation', ct, run_conf, e)
      end
      ThreadReaper.add(thread, nil, group: :durable_lifecycle)
      thread
    end

    def self.log_watcher_failure(kind, ct, run_conf, error)
      OsCtl::Lib::Logger.log(
        :warn,
        "#{ct.ident} lifecycle #{kind} watcher for #{run_conf.run_id} " \
        "failed: #{error.message} (#{error.class})"
      )
    end

    def initialize(ct, run_conf, effect_id)
      @ct = ct
      @run_conf = run_conf
      @effect_id = effect_id
    end

    def execute
      lifecycle.set_effect_worker(run_conf.run_id, effect_id, Process.pid)
      return unless current_effect?

      run_finalizer_hook(:on_stop)
      return unless current_effect?

      run_finalizer_hook(:post_stop)
      return unless current_effect?

      update_hints
      return unless current_effect?

      if run_conf.aborted?
        log(:info, run_conf, 'Container was aborted, performing exact-run cleanup')
      end

      prune_mounts
      return unless current_effect?

      cleanup_cgroups
      return unless current_effect?

      unless lifecycle.other_runtime_generation?(run_conf.run_id)
        CpuScheduler.unschedule_ct(ct)
      end
      return unless current_effect?

      cleanup_apparmor
      return unless current_effect?

      writeout_dataset
      return unless current_effect?

      if run_conf.destroy_dataset_on_stop?
        GarbageCollector.free_container_run_dataset(run_conf, run_conf.dataset)
        return unless current_effect?
      end

      execution_run = lifecycle.execution_run?(run_conf.run_id)
      exit_event = lifecycle.exit_event(run_conf.run_id)
      if exit_event
        Eventd.report(
          :ct_exit,
          pool: ct.pool.name,
          id: ct.id,
          run_id: run_conf.run_id.to_s,
          exit_type: exit_event.to_s
        )
        return unless current_effect?
      end

      run_conf.fulfil_exit
      completed, restart_intent_id =
        lifecycle.complete_run(run_conf.run_id, effect_id)
      return unless completed

      remove_lxc_config
      ct.lxc_config.remove_run_hooks(run_conf)
      run_conf.destroy
      ct.forget_past_run_conf(run_conf)

      if restart_intent_id
        restart_container(restart_intent_id)
      elsif !execution_run && ct.ephemeral? && lifecycle.residuals.empty?
        Commands::Container::Delete.run(
          pool: ct.pool.name,
          id: ct.id,
          force: true,
          manipulation_lock: 'wait'
        )
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      lifecycle.fail_cleanup(run_conf.run_id, effect_id, e.message)
      log(:warn, run_conf, "Lifecycle cleanup failed: #{e.message} (#{e.class})")
      log(:warn, run_conf, denixstorify(e.backtrace).join("\n"))
    ensure
      lifecycle.effect_worker_exited(run_conf.run_id, effect_id)
    end

    protected

    attr_reader :ct, :run_conf, :effect_id

    def lifecycle
      ct.lifecycle
    end

    def current_effect?
      lifecycle.effect_current?(run_conf.run_id, effect_id)
    end

    def update_hints
      ct.update_hints
    rescue Exception => e # rubocop:disable Lint/RescueException
      log(:warn, ct, "Unable to update hints: #{e.message} (#{e.class})")
      log(:warn, ct, denixstorify(e.backtrace).join("\n"))
    end

    def run_finalizer_hook(name)
      run = lifecycle.run(run_conf.run_id)
      return if run&.fetch("#{name}_hook_started", false)
      return unless lifecycle.claim_finalizer_hook(
        run_conf.run_id,
        effect_id,
        name
      )

      error = nil
      begin
        Array(Hook.run(ct, name)).grep(Thread).each(&:join)
      rescue StandardError => e
        error = "#{e.class}: #{e.message}"
        log(:warn, ct, "#{name.to_s.tr('_', '-')} hook failed: #{error}")
        log(:warn, ct, denixstorify(e.backtrace).join("\n"))
      end

      lifecycle.complete_finalizer_hook(
        run_conf.run_id,
        effect_id,
        name,
        error:
      )
    end

    def writeout_dataset
      return if ct.ephemeral?
      return if run_conf.destroy_dataset_on_stop?
      return unless Daemon.get.config.writeout_dirtied_pages?
      return unless run_conf.rootfs

      force_mount = false

      begin
        ct.unmount(force: true)
      rescue SystemCommandFailed => e
        log(:warn, run_conf, "Unable to unmount dataset for writeback: #{e.message}")
        force_mount = true
      end

      ct.mount(force: force_mount)
    end

    def cleanup_apparmor
      return unless AppArmor.enabled?

      ct.apparmor.destroy_namespace(run_conf)
      ct.apparmor.destroy_profile(run_conf)
    end

    def cleanup_cgroups
      Container::Recovery.new(ct).cleanup_generation(run_conf.run_id)
    end

    def prune_mounts
      ct.mounts.prune
    end

    def remove_lxc_config
      File.unlink(ct.lxc_config.run_config_path(run_conf))
    rescue Errno::ENOENT
      nil
    end

    def restart_container(intent_id)
      ct.pool.request_reboot(ct)

      until ct.pool.imported?
        log(:info, ct, 'Waiting for pool import to reboot')
        sleep(1)
      end

      ret = Commands::Container::Start.run(
        pool: ct.pool.name,
        id: ct.id,
        lifecycle_source: 'reconcile',
        lifecycle_intent_id: intent_id,
        manipulation_lock: 'wait'
      )
      return if ret.is_a?(Hash) && ret[:status]

      log(:warn, ct, "Reboot failed: #{ret.inspect}")
    rescue CommandFailed => e
      log(:warn, ct, "Reboot failed: #{e.message}")
    end
  end
end
