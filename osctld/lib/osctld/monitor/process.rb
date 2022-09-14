require 'libosctl'
require 'thread'

module OsCtld
  class Monitor::Process
    include OsCtl::Lib::Utils::Log

    def self.spawn(ct)
      out_r, out_w = IO.pipe

      pid = Process.fork do
        STDOUT.reopen(out_w)
        out_r.close

        SwitchUser.switch_to(
          ct.user.sysusername,
          ct.user.ugid,
          ct.user.homedir,
          File.join(ct.group.full_cgroup_path(ct.user), 'monitor'),
          chown_cgroups: false
        )

        Process.exec('lxc-monitor', '-P', ct.lxc_home, '-n', '.*')
      end

      out_w.close
      [pid, out_r]
    end

    def self.stop_monitord(ct)
      pid = Process.fork do
        SwitchUser.switch_to(
          ct.user.sysusername,
          ct.user.ugid,
          ct.user.homedir,
          File.join(ct.group.full_cgroup_path(ct.user), 'monitor'),
          chown_cgroups: false
        )

        Process.exec('lxc-monitor', '-P', ct.lxc_home, '--quit')
      end

      Process.wait(pid)

      if $?.exitstatus == 0
        log(:info, :monitor, 'Stopped lxc-monitord')

      else
        log(:info, :monitor, 'Failed to stop lxc-monitord')
      end
    end

    def initialize(pool, user, group, stdout)
      @pool = pool
      @user = user
      @group = group
      @stdout = stdout
      @last_line = nil
    end

    def monitor
      # First, get container's current state

      until @stdout.eof?
        line = @stdout.readline
        next if line == @last_line
        @last_line = line

        state = parse(line)
        next unless state

        update_state(state)
      end

      true

    rescue IOError
      log(:info, :monitor, "Monitoring of #{@pool.name}:#{@user.name}:#{@group.name} failed")
      false
    end

    protected
    def parse(line)
      if /'([^']+)' changed state to \[([^\]]+)\]/ =~ line
        log(:info, :monitor, "Container #{@pool.name}:#{$1} entered state #{$2}")
        return {pool: @pool.name, ctid: $1, state: $2.downcase.to_sym}

      elsif /'([^']+)' exited with status \[(\d+)\]/ =~ line
        log(:info, :monitor, "Container #{@pool.name}:#{$1} exited with #{$2}")

      else
        log(:warn, :monitor, "Line from lxc-monitor not recognized: '#{line}'")
      end

      nil
    end

    def update_state(change)
      ct = DB::Containers.find(change[:ctid], change[:pool])

      unless ct
        log(:warn, :monitor, "Container #{change[:pool]}:#{change[:ctid]} not found")
        return
      end

      ct.state = change[:state]

      event_opts = {
        pool: ct.pool.name,
        id: ct.id,
        state: change[:state],
      }

      # Pre-announce handling
      case ct.state
      when :running
        begin
          init_pid = ContainerControl::Commands::State.run!(ct).init_pid
          ct.ensure_run_conf.init_pid = init_pid
          event_opts[:init_pid] = init_pid
        rescue ContainerControl::Error => e
          log(:warn, :monitor, "Unable to get state of container #{ct.ident}: #{e.message}")
          event_opts[:init_pid] = nil
        end

      when :aborting
        ct.run_conf.aborted = true

      when :stopped, :aborted
        ct.mounts.prune
      end

      # Announce state change
      Eventd.report(:state, **event_opts)

      # Post-announce handling
      case ct.state
      when :running
        Hook.run(ct, :post_start, init_pid: ct.init_pid)

      when :stopping
        Hook.run(ct, :on_stop)
      end
    end
  end
end
