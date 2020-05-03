require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Start < Commands::Logged
    handle :ct_start

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      return start_queued(ct) if opts[:queue]

      event_queue = nil

      manipulate(ct) do
        event_queue = Eventd.subscribe
        ret = start_now(ct)

        # Exit if we don't need to wait
        if ret != :wait
          return ret

        elsif opts[:wait] === false
          return ok
        end

        # Wait for the container to enter state `running`
        progress('Waiting for the container to start')
        started = wait_for_ct(event_queue, ct)
        Eventd.unsubscribe(event_queue)

        if started
          # Access `/proc/stat` and `/proc/loadavg` within the container, so that
          # LXCFS starts tracking it immediately.
          begin
            ct_syscmd(ct, 'cat /proc/stat', valid_rcs: :all)
            ct_syscmd(ct, 'cat /proc/loadavg', valid_rcs: :all)
          rescue OsCtld::SystemCommandFailed => e
            log(:warn, ct, "Failed to initiate lxcfs accounting: #{e.message}")
          end

          ok

        else
          error('container failed to start')
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
          start_opts: opts,
        )
        return ok
      end

      ret = ct.pool.autostart_plan.start_ct(
        ct,
        priority: opts[:priority],
        start_opts: opts,
        client_handler: client_handler,
      )

      if ret.nil?
        ok('Timed out')

      else
        ret
      end
    end

    def start_now(ct)
      error!('start not available') unless ct.can_start?
      return ok if ct.running? && !opts[:force]

      # Remove any left-over temporary mounts
      ct.mounts.prune

      # Reset log file
      File.open(ct.log_path, 'w').close
      File.chmod(0660, ct.log_path)
      File.chown(0, ct.user.ugid, ct.log_path)

      # Console dir
      console_dir = File.join(ct.pool.console_dir, ct.id)
      Dir.mkdir(console_dir) unless Dir.exist?(console_dir)
      File.chown(ct.user.ugid, 0, console_dir)
      File.chmod(0700, console_dir)

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
        'pty-wrapper',
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

      r, w = IO.pipe

      progress('Starting container')
      pid = SwitchUser.fork_and_switch_to(
        ct.user.sysusername,
        ct.user.ugid,
        ct.user.homedir,
        ct.cgroup_path,
        prlimits: ct.prlimits.export,
        oom_score_adj: -1000,
      ) do
        r.close

        wrapper_pid = Process.spawn(
          *cmd,
          pgroup: true, in: :close, out: :close, err: :close
        )

        w.puts(wrapper_pid.to_s)
      end

      w.close
      wrapper_pid = r.readline.strip.to_i
      r.close

      progress('Connecting console')

      begin
        Console.connect_tty0(ct, wrapper_pid)
      rescue Errno::ENOENT
        log(:warn, ct, "Unable to connect to tty0")
      end

      Process.wait(pid)
      :wait
    end

    # Wait for the container to start or fail
    def wait_for_ct(event_queue, ct)
      # Sequence of events that lead to the container being started.
      # We're accepting even `stopping` and `stopped`, since when the container
      # is being restarted, these events may be received and should not cause
      # this method to exit.
      sequence = %i(stopping stopped starting running)
      last_i = nil

      loop do
        event = event_queue.pop(timeout: opts[:wait] || 60)
        return false if event.nil?

        # Ignore irrelevant events
        next if event.type != :state \
                || event.opts[:pool] != ct.pool.name \
                || event.opts[:id] != ct.id

        state = event.opts[:state]
        cur_i = sequence.index(state)

        return false if cur_i.nil? || (last_i && cur_i < last_i)
        return true if state == sequence.last

        last_i = cur_i
      end
    end
  end
end
