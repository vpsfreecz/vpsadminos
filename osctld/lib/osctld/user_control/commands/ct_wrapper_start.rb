require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtWrapperStart < UserControl::Commands::Base
    handle :ct_wrapper_start

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      # Move the calling wrapper to user-owned cgroup, which will then be used
      # by LXC
      cgpath = ct.cgroup_path

      log(:debug, ct, "Reattaching wrapper, PID #{opts[:pid]} -> #{cgpath}")
      CGroup.mkpath_all(
        cgpath.split('/'),
        chown: ct.user.ugid,
        attach: true,
        leaf: false,
        pid: opts[:pid],
        debug: true,
      )

      # There's a rare issue when sometimes the PID is not attached to all controllers
      # and is left in the wrapper's cgroup path. It happens especially on node boot.
      ensure_reattached(ct, cgpath, opts[:pid]) if CGroup.v1?

      # Reset oom_score_adj of the calling process. The reset has to come from
      # a process with CAP_SYS_RESOURCE (which osctld is), so that
      # oom_score_adj_min is changed and container users cannot freely set
      # oom_score_adj to -1000.
      log(:debug, ct, "Set /proc/#{opts[:pid]}/oom_score_adj=0")
      File.open(File.join('/proc', opts[:pid].to_s, 'oom_score_adj'), 'w') do |f|
        f.write('0')
      end

      ok
    end

    protected
    def ensure_reattached(ct, cgpath, pid, attempts: 3)
      attempts.times do |i|
        reconfigure = []

        # Look for the PID in cgroup.procs in all subsystems
        CGroup.subsystems.each do |subsys|
          unless CGroup.get_cgroup_pids(subsys, cgpath).include?(pid)
            log(:debug, ct, "PID #{pid} not found in cgroup.procs at #{subsys}:/#{cgpath}, attempt ##{i+1}")
            reconfigure << subsys
          end
        end

        if reconfigure.empty?
          CGroup.get_process_cgroups(pid).each do |subsys, path|
            if path != "/#{cgpath}"
              log(:warn, ct, "PID #{pid} expected in cgroup #{subsys}:/#{cgpath} on attempt ##{i+1}, found in #{path} as read from /proc/#{pid}/cgroup")
            end
          end

          return
        end

        reconfigure.each do |subsys|
          sleep(1)
          log(:debug, ct, "Reattaching wrapper to #{subsys} again, attempt ##{i+1}, PID #{pid} -> #{cgpath}")
          CGroup.mkpath(
            subsys,
            cgpath.split('/'),
            chown: ct.user.ugid,
            attach: true,
            leaf: false,
            pid: pid,
            debug: true,
          )
        end

        sleep(1 + i)
      end

      nil
    end
  end
end
