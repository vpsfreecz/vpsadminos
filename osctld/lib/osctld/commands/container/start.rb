require 'osctld/commands/logged'

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

    def request_stop
      @stop_requested = true
      @pending_wait_token&.fulfil
    end

    def execute(ct)
      return start_queued(ct) if opts[:queue]

      wait_until = start_wait_until

      loop do
        pending_run_conf = nil
        event_queue = nil
        ret = nil

        manipulate(ct) do
          pending_run_conf = ct.get_pending_run_conf

          unless pending_run_conf
            event_queue = Eventd.subscribe
            starting_run_conf = ct.get_starting_run_conf
            ret = starting_run_conf ? [:wait, starting_run_conf] : start_now(ct)
          end
        end

        if pending_run_conf
          ret = wait_for_pending_run(pending_run_conf, ct, wait_until)
          return ret if ret

          next
        end

        if ret.is_a?(Array) && ret[0] == :launch
          ret = finish_wrapper_launch(ct, *ret[1..])
        end

        # Exit if we don't need to wait
        return ret if !ret.is_a?(Array) || ret[0] != :wait
        return ok if opts[:wait] === false

        # The manipulation lock must not be held while waiting. A reboot
        # requested from inside the container needs the same lock to start the
        # next run.
        progress('Waiting for the container to start')
        started, msg = wait_for_ct(event_queue, ct, ret[1], wait_until)

        case started
        when :running
          return ok
        when :timeout
          return error(msg || 'timed out while waiting for container to start')
        when :error
          return error(msg || 'container failed to start')
        else
          return error(msg || 'unknown error')
        end
      ensure
        Eventd.unsubscribe(event_queue) if event_queue
      end
    end

    protected

    def start_wait_until
      if opts[:wait] == 'infinity' || opts[:wait] === false
        nil
      else
        Time.now + (opts[:wait] || Container::DEFAULT_START_TIMEOUT)
      end
    end

    def wait_for_pending_run(run_conf, ct, wait_until)
      if opts[:wait] === false
        return error('previous container run is still stopping')
      end

      if ct.owns_manipulation_lock?
        return error('previous container run is still stopping')
      end

      if run_conf.runtime_unknown?
        progress('Waiting to identify the existing container run')
        promise = run_conf.get_runtime_resolution_promise
      else
        progress('Waiting for the previous container run to stop')
        promise = run_conf.get_exit_promise
      end

      @pending_wait_token = promise

      if @stop_requested || Daemon.get.stopping?
        log(:info, ct, 'osctld is shutting down, giving up waiting')
        return error('osctld is shutting down')
      end

      timeout = wait_until - Time.now if wait_until

      if timeout && timeout <= 0
        return error('timed out while waiting for previous container run to stop')
      end

      fulfilled = promise.wait(timeout:)

      if @stop_requested || Daemon.get.stopping?
        log(:info, ct, 'osctld is shutting down, giving up waiting')
        return error('osctld is shutting down')
      end

      return if fulfilled

      error('timed out while waiting for previous container run to stop')
    ensure
      @pending_wait_token = nil if @pending_wait_token.equal?(promise)
    end

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

    def start_now(ct)
      error!('start not available') unless ct.can_start?
      return ok if %i[starting running].include?(ct.state) && !opts[:force]

      # Remove pre-existing accounting cgroups to reset counters
      remove_accounting_cgroups(ct)

      # Initiate run configuration
      ct.init_run_conf

      # NixOS impermanence
      if ct.impermanence && ct.distribution == 'nixos' && !opts[:custom_boot]
        setup_impermanence(ct.run_conf)
      end

      # Remove any left-over temporary mounts
      ct.mounts.prune

      # Mount datasets
      begin
        ct.run_conf.mount
      rescue SystemCommandFailed => e
        return error("failed to mount dataset: #{e.message}")
      end

      # Pre-start distconfig hook
      DistConfig.run(ct.run_conf, :pre_start)

      # CPU scheduler
      CpuScheduler.schedule_ct(ct.run_conf)

      # Optionally add new mounts
      (opts[:mounts] || []).each do |mnt|
        ct.mounts.add(mnt)
      end

      # Reset log file
      File.open(ct.log_path, 'w').close
      File.chmod(0o660, ct.log_path)
      File.chown(0, ct.user.ugid, ct.log_path)

      # Update LXC configuration
      ct.lxc_config.configure

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
        'lxc-start',
        '-P', ct.lxc_home,
        '-n', ct.id,
        '-o', ct.log_path,
        '-l', opts[:debug] ? 'DEBUG' : 'ERROR',
        '-F'
      ]

      # Bind before launching the wrapper. The listener itself is the durable
      # identity across an abrupt osctld restart: if it can be connected, a
      # wrapper inherited it; if not, the path is merely stale and cleanup can
      # safely resume.
      listener = UNIXServer.new(sock_path)
      File.chown(ct.user.ugid, 0, sock_path)

      console_io = UNIXSocket.new(sock_path)
      ready_r, ready_w = IO.pipe
      run_conf = ct.start_pending
      console_attached = false
      launch_returned = false

      Console.attach_tty0(ct, nil, console_io, run_conf, ready: false)
      console_attached = true

      progress('Starting container')
      pid = SwitchUser.fork_and_switch_to(
        ct.user.sysusername,
        ct.user.ugid,
        ct.user.homedir,
        ct.wrapper_cgroup_path,
        prlimits: ct.prlimits.export,
        oom_score_adj: -1000,
        keep_fds: [ready_w, listener],
        syslogns_tag: ct.syslogns_tag
      ) do
        # Closed by SwitchUser.fork_and_switch_to
        # ready_r.close

        # This is to remove all Ruby related environment variables, because
        # lxc-start then passes them to hooks, which can make the hooks fail
        # when ruby or osctld gems are upgraded.
        SwitchUser.clear_ruby_env

        begin
          Process.spawn(
            {
              'OSCTLD_CT_WRAPPER_LISTENER_FD' => listener.fileno.to_s,
              'OSCTLD_CT_WRAPPER_READY_FD' => ready_w.fileno.to_s
            },
            *cmd,
            pgroup: true, in: :close, out: :close, err: :close,
            listener => listener,
            ready_w => ready_w
          )
        ensure
          listener.close
          ready_w.close
        end
      end

      ready_w.close
      listener.close
      Process.wait(pid)

      launch_returned = true
      [:launch, run_conf, ready_r]
    rescue StandardError
      ct.abort_start(run_conf) if run_conf && !console_attached
      raise
    ensure
      [listener, ready_w].each do |io|
        io&.close unless io&.closed?
      end

      console_io&.close unless console_attached || console_io&.closed?
      ready_r&.close unless launch_returned || ready_r&.closed?
    end

    # Complete the event-driven handoff from the wrapper outside of the
    # manipulation lock. This may wait indefinitely when the host is
    # overloaded, but it cannot prevent stop cleanup or a queued reboot from
    # acquiring the lock.
    def finish_wrapper_launch(ct, run_conf, ready_io)
      # Daemon shutdown also waits for readiness or EOF. Once readiness is
      # received, the console socket is an exact identity which the next daemon
      # can reconnect to.
      ready_signal = ready_io.read(1)

      if ready_signal != '1'
        return error('container wrapper failed to start')
      end

      unless Console.activate_tty0(ct, run_conf)
        return error('container wrapper console closed before becoming ready')
      end

      [:wait, run_conf]
    ensure
      ready_io.close unless ready_io.closed?
    end

    # Wait for the container to start or fail
    # @return [Array<Symbol, String>] :running, :timeout or :error and string message
    def wait_for_ct(event_queue, ct, run_conf, wait_until)
      # Sequence of events that lead to the container being started.
      # We're accepting even `stopping` and `stopped`, since when the container
      # is being restarted, these events may be received and should not cause
      # this method to exit.
      sequence = %i[stopping stopped starting running]
      last_i = nil
      shutdown_wait_until = nil

      loop do
        if Daemon.get.stopping?
          shutdown_wait_until ||= Time.now + 15

          if Time.now >= shutdown_wait_until
            log(:info, ct, 'osctld is shutting down, giving up waiting')
            return [:error, 'osctld is shutting down']
          end
        end

        if wait_until
          timeout = wait_until - Time.now
          return [:timeout] if timeout < 0
        end

        if shutdown_wait_until
          shutdown_timeout = shutdown_wait_until - Time.now
          timeout = timeout.nil? ? shutdown_timeout : [timeout, shutdown_timeout].min
        end

        timeout = 15 if timeout.nil? || timeout > 15

        event = event_queue.pop(timeout:)

        if event.nil?
          if Daemon.get.stopping?
            log(:info, ct, 'osctld is shutting down, giving up waiting')
            return [:error, 'osctld is shutting down']
          end

          next
        end

        if event.type == :osctld_shutdown
          log(:info, ct, 'osctld is shutting down, giving up waiting')
          return [:error, 'osctld is shutting down']
        elsif event.type == :state_recovery \
              && event.opts[:pool] == ct.pool.name \
              && event.opts[:id] == ct.id \
              && event.opts[:state] == :stopped
          return [:error, 'start failed, container is found to be stopped']
        elsif event.type == :ct_start_failed \
              && event.opts[:pool] == ct.pool.name \
              && event.opts[:id] == ct.id \
              && event.opts[:run_id] == run_conf.run_id.to_s
          return [:error, event.opts[:message]]
        end

        # Ignore irrelevant events
        next if event.type != :state \
                || event.opts[:pool] != ct.pool.name \
                || event.opts[:id] != ct.id

        state = event.opts[:state]
        cur_i = sequence.index(state)

        return [:error] if cur_i.nil? || (last_i && cur_i < last_i)
        return [:running] if state == sequence.last

        last_i = cur_i
      end
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
