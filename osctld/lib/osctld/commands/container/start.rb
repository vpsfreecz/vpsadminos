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

        in_pipe, out_pipe = Console.tty0_pipes(ct)

        cmd = [
          OsCtld.bin('osctld-ct-wrapper'),
          "#{ct.pool.name}:#{ct.id}",
          in_pipe, out_pipe,
          'lxc-start',
          '-P', ct.lxc_home,
          '-n', ct.id,
          '-o', ct.log_path,
          '-F'
        ]

        mkfifo(in_pipe, 'w')
        mkfifo(out_pipe, 'r')

        [in_pipe, out_pipe].each do |pipe|
          File.chown(0, ct.user.ugid, pipe)
        end

        File.chmod(0640, in_pipe)
        File.chmod(0660, out_pipe)

        progress('Starting container')
        pid = Process.fork do
          in_r = File.open(in_pipe, 'r')
          out_w = File.open(out_pipe, 'w')

          STDIN.reopen(in_r)
          STDOUT.reopen(out_w)
          STDERR.reopen(out_w)

          SwitchUser.switch_to(
            ct.user.sysusername,
            ct.user.ugid,
            ct.user.homedir,
            ct.cgroup_path
          )
          Process.spawn(*cmd, pgroup: true)
        end

        in_w = File.open(in_pipe, 'w')
        out_r = File.open(out_pipe, 'r')

        progress('Connecting console')
        Console.connect_tty0(ct, pid, in_w, out_r)
        Process.wait(pid)

        :wait
      end

      # Exit if we don't need to wait
      return ret if ret != :wait

      # Wait for the container to enter state `running`
      progress('Waiting for the container to start')
      started = wait_for_ct(event_queue, ct)
      Eventd.unsubscribe(event_queue)

      if started
        # Access `/proc/loadavg` within the container, so that LXCFS starts
        # tracking it immediately.
        ct.inclusively do
          ct_syscmd(ct, 'cat /proc/loadavg', valid_rcs: :all)
        end

        ok

      else
        error('container failed to start')
      end
    end

    protected
    # Wait for the container to start or fail
    #
    # TODO: if, for some reason, no relevant state change event is received,
    # this method is going to block. It would be best to add a timeout.
    def wait_for_ct(event_queue, ct)
      # Sequence of events that lead to the container being started.
      # We're accepting even `stopping` and `stopped`, since when the container
      # is being restarted, these events may be received and should not cause
      # this method to exit.
      sequence = %i(stopping stopped starting running)
      last_i = nil

      loop do
        event = event_queue.pop

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

    def mkfifo(path, mode)
      syscmd("mkfifo \"#{path}\"") unless File.exist?(path)
    end
  end
end
