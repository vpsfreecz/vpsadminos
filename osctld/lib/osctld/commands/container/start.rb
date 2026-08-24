require 'osctld/commands/logged'
require 'osctld/commands/group/cgparam_apply'

module OsCtld
  class Commands::Container::Start < Commands::Logged
    handle :ct_start

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Container
    include Utils::SwitchUser

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      daemon = Daemon.get

      if opts[:queue]
        manipulate(ct, lifecycle: true) do
          ensure_config_ready!(ct)
          error!('start not available') unless ct.can_start?
        end
        return start_queued(ct)
      end

      deadline = wait_deadline
      intent_id = opts[:lifecycle_intent_id]
      admission_opts = {
        internal: client_handler.nil?,
        continuation: indirect? && !intent_id.nil?,
        recovery: client_handler.nil? && opts[:lifecycle_recovery] == true
      }

      loop do
        request, preflight_error = manipulate(ct, lifecycle: true) do
          ensure_config_ready!(ct)
          error!('start not available') unless ct.can_start?

          daemon.with_lifecycle_admission_context(**admission_opts) do
            if ct.lifecycle.active_run_id.nil?
              ret = call_cmd(
                Commands::Group::CGParamApply,
                name: ct.group.name,
                pool: ct.pool.name,
                manipulation_lock: 'wait',
                only_policies: true
              )
              next [nil, ret] unless ret[:status]
            end

            daemon.with_lifecycle_admission(**admission_opts) do
              [
                ct.lifecycle.request_start(
                  source: opts[:lifecycle_source] || 'external',
                  expected_intent_id: intent_id
                ),
                nil
              ]
            end
          end
        end
        return preflight_error if preflight_error

        intent_id ||= request.intent_id
        progress(request.warning) if request.warning

        case request.action
        when :superseded
          return error('container start intent was superseded')

        when :blocked
          return error(request.warning || 'container lifecycle start is blocked')

        when :running
          return ok(start_output(request, 'running'))

        when :wait
          return accepted(request) if opts[:wait] == false

          progress('Waiting for previous container generation cleanup')
          changed = ct.lifecycle.wait_for_change(
            request.revision,
            timeout: remaining_wait(deadline)
          )
          return error('osctld is shutting down') if changed == :shutdown
          return error('timed out while waiting for container cleanup') unless changed

        when :join
          return accepted(request) if opts[:wait] == false

          ret = wait_for_run(ct, request.run_id, deadline)
          next if ret == :retry

          return ret

        when :launch
          launch_in_background(ct, request)
          return accepted(request) if opts[:wait] == false

          ret = wait_for_run(ct, request.run_id, deadline)
          next if ret == :retry

          return ret

        when :failed
          run = ct.lifecycle.run(request.run_id)
          return error((run && run['error']) || 'container lifecycle cleanup failed')

        else
          return error("unsupported lifecycle action #{request.action.inspect}")
        end
      end
    end

    protected

    def start_queued(ct)
      progress('Joining the queue')

      if opts[:wait] === false
        ct.pool.autostart_plan.enqueue(
          ct,
          priority: opts[:priority],
          start_opts: opts
        )
        return ok
      end

      ret = ct.pool.autostart_plan.start_ct(
        ct,
        priority: opts[:priority],
        start_opts: opts,
        client_handler:
      )

      if ret.nil?
        ok('Timed out')

      else
        ret
      end
    end

    def launch_in_background(ct, request)
      thread = Thread.new do
        launch(ct, request, report_progress: false)
      rescue StandardError => e
        log(:warn, ct, "Background start failed: #{e.message} (#{e.class})")
      end
      ThreadReaper.add(thread, nil, group: :durable_lifecycle)
    end

    def launch(ct, request, report_progress: true)
      effect_id = ct.lifecycle.claim_effect(
        request.run_id,
        :start,
        expected_intent_id: request.intent_id
      )
      return unless effect_id

      acquired = Container::LifecycleExecutor.acquire(ct.pool, :start, effect_id)
      return unless acquired

      ct.lifecycle.set_effect_worker(request.run_id, effect_id, Process.pid)
      return unless ensure_effect!(
        ct,
        request.run_id,
        effect_id,
        expected_intent_id: request.intent_id
      )

      run_conf = ct.init_run_conf(run_id: request.run_id)
      ensure_effect!(
        ct,
        request.run_id,
        effect_id,
        expected_intent_id: request.intent_id
      )
      if ct.impermanence && ct.distribution == 'nixos' && !opts[:custom_boot]
        setup_impermanence(run_conf)
        run_conf.save
        ensure_effect!(
          ct,
          request.run_id,
          effect_id,
          expected_intent_id: request.intent_id
        )
      end
      hook_paths = ct.netifs.flat_map do |netif|
        if netif.respond_to?(:run_hook_paths)
          netif.run_hook_paths(run_conf)
        else
          []
        end
      end
      recorded = ct.lifecycle.record_resources(
        request.run_id,
        {
          dataset: run_conf.dataset.to_s,
          rootfs: run_conf.rootfs,
          mounts: ct.mounts.all_entries.map(&:dump),
          console_socket: Console.socket_path(ct),
          lxc_config: ct.lxc_config.run_config_path(run_conf),
          apparmor_profile: ct.apparmor.profile_name(run_conf),
          apparmor_namespace: ct.apparmor.namespace(run_conf),
          network_hook_paths: hook_paths
        },
        effect_id:,
        intent_id: request.intent_id
      )
      raise CommandFailed, 'container lifecycle effect was superseded' unless recorded

      wrapper_pid = nil

      launch_run(
        ct,
        run_conf,
        request.run_id,
        effect_id,
        request.intent_id,
        report_progress:
      ) do |pid|
        wrapper_pid = pid
      end

      if ct.lifecycle.finish_effect(request.run_id, effect_id)
        spawn_finalizer_if_ready(ct, run_conf, request.run_id)
      end
    rescue StandardError => e
      if wrapper_pid
        log(
          :warn,
          ct,
          "Start effect #{effect_id} failed after wrapper #{wrapper_pid}: #{e.message}"
        )
        finish_dead_wrapper(ct, run_conf, request.run_id, effect_id)
      elsif effect_id && ct.lifecycle.effect_current?(request.run_id, effect_id)
        ct.lifecycle.fail_launch(request.run_id, effect_id, e.message)
        ct.abort_run_conf(run_conf) if run_conf
      end

      raise
    ensure
      if effect_id
        ct.lifecycle.effect_worker_exited(request.run_id, effect_id)
        Container::LifecycleExecutor.release(ct.pool, :start, effect_id)
      end
    end

    def launch_run(
      ct,
      run_conf,
      run_id,
      effect_id,
      intent_id,
      report_progress:
    )
      # Every generation has a random cgroup root, so no previous accounting
      # cgroup is reused or removed here.
      ensure_effect!(ct, run_id, effect_id, expected_intent_id: intent_id)

      # Remove any left-over temporary mounts
      ct.mounts.prune
      ensure_effect!(ct, run_id, effect_id, expected_intent_id: intent_id)

      # Mount datasets
      begin
        run_conf.mount
      rescue SystemCommandFailed => e
        raise CommandFailed, "failed to mount dataset: #{e.message}"
      end
      ensure_effect!(ct, run_id, effect_id, expected_intent_id: intent_id)

      # Pre-start distconfig hook
      DistConfig.run(run_conf, :pre_start)
      ensure_effect!(ct, run_id, effect_id, expected_intent_id: intent_id)

      # CPU scheduler
      CpuScheduler.schedule_ct(run_conf)
      ensure_effect!(ct, run_id, effect_id, expected_intent_id: intent_id)

      # Apply configured or scheduler-selected cpusets to the stable policy
      # root and every live lifecycle generation before LXC creates children.
      ct.cgparams.apply_cpuset_for_start(run_id:)
      ensure_effect!(ct, run_id, effect_id, expected_intent_id: intent_id)

      # Optionally add new mounts
      (opts[:mounts] || []).each do |mnt|
        ct.mounts.add(mnt)
        ensure_effect!(ct, run_id, effect_id, expected_intent_id: intent_id)
      end

      # Reset log file
      File.open(ct.log_path, 'w').close
      File.chmod(0o660, ct.log_path)
      File.chown(0, ct.user.ugid, ct.log_path)
      ensure_effect!(ct, run_id, effect_id, expected_intent_id: intent_id)

      # Update LXC configuration
      ct.lxc_config.configure(run_conf:)
      ensure_effect!(ct, run_id, effect_id, expected_intent_id: intent_id)

      # Console dir
      console_dir = File.join(ct.pool.console_dir, ct.id)
      FileUtils.mkdir_p(console_dir)
      File.chown(ct.user.ugid, 0, console_dir)
      File.chmod(0o700, console_dir)

      # Remove stray sockets
      sock_path = Console.socket_path(ct)
      if File.exist?(sock_path)
        log(:info, ct, "Removing leftover tty0 socket at #{sock_path}")

        begin
          File.unlink(sock_path)
        rescue Errno::ENOENT
          # Continue if the socket was already deleted
        end
      end

      # Containers are started through two wrappers: pty-wrapper and osctld-ct-start.
      #
      # pty-wrapper is used to allocate a pty and provide access to input/output
      # of the started process.
      #
      # osctld-ct-start is used to reset oom_score_adj to zero, since pty-wrapper
      # have its own oom_score_adj set to -1000 to ensure the OOM killer will
      # not target it. oom_score_adj is inherited on fork, so the process
      # pty-wrapper starts has it set to -1000 as well. Because the process
      # is already run as an unprivileged user, changing oom_score_adj will leave
      # oom_score_adj_min untouched. That would let all container users to disable
      # OOM killer altogether, so osctld-ct-start pings back to osctld, which is
      # running with CAP_SYS_RESOURCE and can set both obj_score_adj and
      # obj_score_adj_min to zero. When it's done, osctld-ct-start execs to
      # lxc-start.
      cmd = [
        Daemon.get.config.ct_wrapper,
        "#{ct.pool.name}:#{ct.id}",
        Console.socket_path(ct),
        OsCtld.bin('osctld-ct-start'),
        ct.pool.name,
        ct.id,
        run_id.to_s,
        'lxc-start',
        '-P', ct.lxc_home,
        '-n', ct.id,
        '-f', ct.lxc_config.run_config_path(run_conf),
        '-o', ct.log_path,
        '-l', opts[:debug] ? 'DEBUG' : 'ERROR',
        '-F'
      ]

      ensure_effect!(ct, run_id, effect_id, expected_intent_id: intent_id)
      progress('Starting container') if report_progress
      pid = SwitchUser.fork_and_switch_to(
        ct.user.sysusername,
        ct.user.ugid,
        ct.user.homedir,
        run_conf.wrapper_cgroup_path,
        prlimits: ct.prlimits.export,
        oom_score_adj: -1000,
        syslogns_tag: ct.syslogns_tag,
        before_continue: proc do |child_pid|
          yield(child_pid)
          unless ct.lifecycle.mark_launching(run_id, effect_id, child_pid)
            raise CommandFailed, 'container start was superseded by recovery'
          end
        end
      ) do
        # This is to remove all Ruby related environment variables, because
        # lxc-start then passes them to hooks, which can make the hooks fail
        # when ruby or osctld gems are upgraded.
        SwitchUser.clear_ruby_env

        Process.exec(
          *cmd,
          pgroup: true, in: :close, out: :close, err: :close
        )
      end

      wrapper_pid = pid
      Container::LifecycleFinalizer.watch_wrapper(
        ct,
        run_conf,
        child_pid: pid
      )

      progress('Connecting console') if report_progress
      complete_launch_handoff(
        ct,
        wrapper_pid,
        run_conf,
        run_id,
        effect_id
      )

      true
    end

    def complete_launch_handoff(ct, wrapper_pid, run_conf, run_id, effect_id)
      Console.connect_tty0(
        ct,
        wrapper_pid,
        run_conf,
        effect_id:,
        intent_id: nil
      )

      handoff = ct.lifecycle.wait_for_launch_handoff(run_id, effect_id)
      unless handoff == :complete
        raise CommandFailed, "container launch handoff ended as #{handoff}"
      end

      true
    end

    def wait_for_run(ct, run_id, deadline)
      progress('Waiting for the container to start')
      phase = ct.lifecycle.wait_for_start(run_id, timeout: remaining_wait(deadline))

      case phase
      when :running
        ok(
          run_id: run_id.to_s,
          lifecycle_revision: ct.lifecycle.revision,
          lifecycle_state: 'running'
        )
      when :timeout
        error('timed out while waiting for container to start')
      when :failed, :clean
        run = ct.lifecycle.run(run_id)
        if run&.has_key?('launch_intent_id') \
            && ct.lifecycle.desired_state == :running \
            && ct.lifecycle.current_intent_id != run['launch_intent_id']
          return :retry
        end

        if phase == :clean
          error('container stopped before start completed')
        else
          error((run && run['error']) || 'container failed to start')
        end
      when :cleanup_failed
        run = ct.lifecycle.run(run_id)
        error((run && run['error']) || 'container lifecycle cleanup failed')
      when :quarantined
        error('container start was superseded by recovery')
      when :shutdown
        error('osctld is shutting down')
      else
        error("container start ended in lifecycle state #{phase}")
      end
    end

    def accepted(request)
      ok(start_output(request, 'accepted'))
    end

    def start_output(request, state)
      {
        run_id: request.run_id.to_s,
        lifecycle_revision: request.revision,
        lifecycle_state: state,
        warning: request.warning
      }.compact
    end

    def wait_deadline
      return if [false, 'infinity'].include?(opts[:wait])

      monotonic_now + (opts[:wait] || Container::DEFAULT_START_TIMEOUT)
    end

    def remaining_wait(deadline)
      return unless deadline

      [deadline - monotonic_now, 0].max
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def ensure_effect!(ct, run_id, effect_id, expected_intent_id: nil)
      current = ct.lifecycle.effect_current?(run_id, effect_id)
      intent_current =
        expected_intent_id.nil? \
          || ct.lifecycle.current_intent_id == expected_intent_id
      return true if current && intent_current

      raise CommandFailed, 'container lifecycle effect was superseded'
    end

    def finish_dead_wrapper(ct, run_conf, run_id, effect_id)
      run = ct.lifecycle.run(run_id)
      wrapper = run && run['wrapper'] && ProcessIdentity.load(run['wrapper'])
      return unless ct.lifecycle.finish_effect(run_id, effect_id)
      return if wrapper&.alive?

      finalize_effect_id = ct.lifecycle.observe_wrapper_gone(run_id)
      if finalize_effect_id && run_conf
        Container::LifecycleFinalizer.spawn(ct, run_conf, finalize_effect_id)
      else
        begin
          Container::Recovery.new(ct).recover_state(run_id:)
        rescue Container::Recovery::Busy
          nil
        end
      end
    end

    def spawn_finalizer_if_ready(ct, run_conf, run_id)
      finalize_effect_id = ct.lifecycle.claim_finalization(run_id)
      unless finalize_effect_id
        run = ct.lifecycle.run(run_id)
        if run&.fetch('wrapper_gone', false) && !run.fetch('post_stop', false)
          begin
            Container::Recovery.new(ct).recover_state(run_id:)
          rescue Container::Recovery::Busy
            nil
          end
        end
        return
      end
      return unless run_conf

      Container::LifecycleFinalizer.spawn(
        ct,
        run_conf,
        finalize_effect_id
      )
    end

    def setup_impermanence(ctrc)
      tmp_name = "#{ctrc.ct.dataset}.impermanence-#{SecureRandom.hex(3)}"

      tmp_ds = OsCtl::Lib::Zfs::Dataset.new(
        tmp_name,
        base: tmp_name
      )
      tmp_ds.create!(properties: {
        canmount: 'noauto'
      }.merge(ctrc.ct.impermanence.zfs_properties))

      GarbageCollector.add_container_run_dataset(ctrc, tmp_ds)

      ctrc.boot_from(
        dataset: tmp_ds,
        distribution: ctrc.distribution,
        version: ctrc.version,
        arch: ctrc.arch,
        vendor: ctrc.vendor,
        variant: ctrc.variant,
        destroy_dataset_on_stop: true
      )

      builder = Container::Builder.new(ctrc, cmd: self)
      builder.shift_or_mount_dataset
      builder.setup_ct_dir
      builder.setup_rootfs

      %w[boot dev etc proc run sbin sys var].each do |dir|
        Dir.mkdir(File.join(ctrc.rootfs, dir))
      end
    end
  end
end
