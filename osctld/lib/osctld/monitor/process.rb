require 'thread'

module OsCtld
  class Monitor::Process
    include Utils::Log
    include Utils::SwitchUser

    def self.spawn(ct)
      out_r, out_w = IO.pipe

      pid = Process.fork do
        STDOUT.reopen(out_w)
        out_r.close

        SwitchUser.switch_to(
          ct.user.sysusername,
          ct.user.ugid,
          ct.user.homedir,
          ct.group.full_cgroup_path(ct.user)
        )

        Process.exec('lxc-monitor', '-P', ct.lxc_home, '-n', '.*')
      end

      out_w.close
      [pid, out_r]
    end

    def initialize(ct, stdout)
      @ct = ct
      @stdout = stdout
    end

    def monitor
      # First, get container's current state

      until @stdout.eof?
        state = parse(@stdout.readline)
        next unless state

        update_state(state)
      end

      true

    rescue IOError
      log(:info, :monitor, "Monitoring of #{@ct.id} failed")
      false
    end

    protected
    def parse(line)
      if /'([^']+)' changed state to \[([^\]]+)\]/ =~ line
        log(:info, :monitor, "Container #{$1} entered state #{$2}")
        return {ctid: $1, state: $2.downcase.to_sym}

      elsif /'([^']+)' exited with status \[(\d+)\]/ =~ line
        log(:info, :monitor, "Container #{$1} exited with #{$2}")

      else
        log(:warn, :monitor, "Line from lxc-monitor not recognized: '#{line}'")
      end

      nil
    end

    def update_state(change)
      ct = ContainerList.find(change[:ctid])

      unless ct
        log(:warn, :monitor, "Container '#{change[:ctid]}' not found")
        return
      end

      ct.inclusively do
        ct.state = change[:state]

        case ct.state
        when :running
          ret = ct_control(ct, :ct_status, ids: [ct.id])
          ct.init_pid = ret[:output][ct.id.to_sym][:init_pid] if ret[:status]
        end
      end
    end
  end
end
