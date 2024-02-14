require 'libosctl'

module OsCtld
  class Monitor::Process
    include OsCtl::Lib::Utils::Log

    def self.spawn(ct)
      cg_path = cgroup_path(ct)
      out_r, out_w = IO.pipe

      CGroup.mkpath_all(cg_path.split('/'))

      pid = Process.fork do
        $stdout.reopen(out_w)
        out_r.close

        SwitchUser.switch_to(
          ct.user.sysusername,
          ct.user.ugid,
          ct.user.homedir,
          cg_path
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
          cgroup_path(ct)
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

    def self.cgroup_path(ct)
      File.join(ct.group.full_cgroup_path(ct.user), 'monitor')
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
        log(:info, :monitor, "Container #{@pool.name}:#{::Regexp.last_match(1)} entered state #{::Regexp.last_match(2)}")
        return { pool: @pool.name, ctid: ::Regexp.last_match(1), state: ::Regexp.last_match(2).downcase.to_sym }

      elsif /'([^']+)' exited with status \[(\d+)\]/ =~ line
        log(:info, :monitor, "Container #{@pool.name}:#{::Regexp.last_match(1)} exited with #{::Regexp.last_match(2)}")

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

      Eventd.report(:state, pool: ct.pool.name, id: ct.id, state: change[:state])

      ct.state = change[:state]
      init_pid = nil

      case ct.state
      when :running
        begin
          init_pid = ContainerControl::Commands::State.run!(ct).init_pid
          ct.ensure_run_conf.init_pid = init_pid
        rescue ContainerControl::Error => e
          log(:warn, :monitor, "Unable to get state of container #{ct.ident}: #{e.message}")
        end

        if init_pid
          Eventd.report(:ct_init_pid, pool: ct.pool.name, id: ct.id, init_pid:)
        end

        Hook.run(ct, :post_start, init_pid: ct.init_pid)

      when :aborting
        # It has happened that ct.run_conf was nil, circumstances unknown
        ct.ensure_run_conf.aborted = true

      when :stopping
        Hook.run(ct, :on_stop)

      when :stopped, :aborted
        ct.mounts.prune
      end
    end
  end
end
