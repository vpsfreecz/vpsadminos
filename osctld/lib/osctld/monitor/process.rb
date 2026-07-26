require 'libosctl'
require 'osctld/cgroup'

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

      _, status = Process.wait2(pid)

      if status.exitstatus == 0
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

      return if ct.state == :error

      run_id = ct.lifecycle.active_run_id

      unless run_id
        log(
          :warn,
          :monitor,
          "Ignoring unowned LXC state #{change[:state]} for #{ct.ident}; " \
          'manual lxc-start is unsupported'
        )
        return
      end

      if %i[stopped aborted].include?(change[:state])
        log(
          :info,
          :monitor,
          "Ignoring generation-ambiguous LXC state #{change[:state]} for " \
          "#{ct.ident}; waiting for the exact post-stop callback"
        )
        return
      end

      begin
        observed = ContainerControl::Commands::State.run!(ct)
      rescue ContainerControl::Error => e
        log(:warn, :monitor, "Unable to qualify state of container #{ct.ident}: #{e.message}")
        return
      end

      if observed.state != change[:state]
        log(
          :info,
          :monitor,
          "Ignoring stale LXC state #{change[:state]} for #{ct.ident}; " \
          "current state is #{observed.state}"
        )
        return
      end

      init_pid = observed.init_pid
      unless generation_pid?(ct, run_id, init_pid)
        log(
          :warn,
          :monitor,
          "Ignoring unqualified init PID #{init_pid} for #{ct.ident} " \
          "run #{run_id}"
        )
        return
      end

      observer_id = ct.lifecycle.begin_state_observation(
        run_id,
        change[:state],
        init_pid:,
        source: 'monitor'
      )
      return unless observer_id
      return if ct.lifecycle.execution_run?(run_id)

      unless ct.observe_run_state(run_id, change[:state], init_pid:)
        log(
          :info,
          :monitor,
          "Ignoring stale LXC state #{change[:state]} for #{ct.ident} run #{run_id}"
        )
        return
      end

      return unless ct.lifecycle.state_observation_current?(run_id, observer_id)
      return unless ct.lifecycle.claim_state_effects(
        run_id,
        observer_id,
        change[:state]
      )

      Eventd.report(
        :state,
        pool: ct.pool.name,
        id: ct.id,
        state: change[:state]
      )

      if change[:state] == :running
        if init_pid
          Eventd.report(:ct_init_pid, pool: ct.pool.name, id: ct.id, init_pid:)
        end

        error = nil
        begin
          Hook.run(ct, :post_start, init_pid:)
        rescue StandardError => e
          error = "#{e.class}: #{e.message}"
          log(:warn, :monitor, "Post-start hook failed for #{ct.ident}: #{error}")
        ensure
          ct.lifecycle.complete_running_effects(
            run_id,
            observer_id,
            error:
          )
        end
      end
    ensure
      if ct && run_id && observer_id
        effect_id = ct.lifecycle.finish_state_observation(run_id, observer_id)
        if effect_id
          run_conf = [ct.run_conf, ct.get_past_run_conf].compact.detect do |conf|
            conf.run_id == run_id
          end
          Container::LifecycleFinalizer.spawn(ct, run_conf, effect_id) if run_conf
        end
      end
    end

    def generation_pid?(ct, run_id, pid)
      return false unless pid

      run = ct.lifecycle.run(run_id)
      return false unless run

      CGroup.get_tree_pids(run.fetch('resources').fetch('cgroup_root')).include?(pid)
    end
  end
end
