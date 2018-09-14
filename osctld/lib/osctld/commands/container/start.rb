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

      ret = ct.exclusively do
        next error('start not available') unless ct.can_start?
        next ok if ct.running? && !opts[:force]

        # Remove any left-over temporary mounts
        ct.mounts.prune

        event_queue = Eventd.subscribe

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
          File.unlink(sock_path)
        end

        cmd = [
          OsCtld.bin('osctld-ct-wrapper'),
          "#{ct.pool.name}:#{ct.id}",
          Console.socket_path(ct),
          'lxc-start',
          '-P', ct.lxc_home,
          '-n', ct.id,
          '-o', ct.log_path,
          '-l', opts[:debug] ? 'DEBUG' : 'ERROR',
          '-F'
        ]

        progress('Starting container')
        pid = Process.fork do
          SwitchUser.switch_to(
            ct.user.sysusername,
            ct.user.ugid,
            ct.user.homedir,
            ct.cgroup_path
          )
          Process.spawn(*cmd, pgroup: true, in: :close, out: :close, err: :close)
        end

        progress('Connecting console')

        begin
          Console.connect_tty0(ct, pid)
        rescue Errno::ENOENT
          log(:warn, ct, "Unable to connect to tty0")
        end

        Process.wait(pid)

        :wait
      end

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
        ct.inclusively do
          ct_syscmd(ct, 'cat /proc/stat', valid_rcs: :all)
          ct_syscmd(ct, 'cat /proc/loadavg', valid_rcs: :all)
        end

        ok

      else
        error('container failed to start')
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
