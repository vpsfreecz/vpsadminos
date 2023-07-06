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
      if CGroup.v1?
        reconfigure = []

        CGroup.get_process_cgroups(opts[:pid]).each do |subsys, path|
          if path != "/#{cgpath}"
            log(:debug, ct, "PID #{opts[:pid]} expected in cgroup #{subsys}:/#{cgpath}, found in #{path}")
            reconfigure << subsys
          end
        end

        reconfigure.each do |subsys|
          sleep(1)
          log(:debug, ct, "Reattaching wrapper to #{subsys} again, PID #{opts[:pid]} -> #{cgpath}")
          CGroup.mkpath(
            subsys,
            cgpath.split('/'),
            chown: ct.user.ugid,
            attach: true,
            leaf: false,
            pid: opts[:pid],
            debug: true,
          )
        end
      end

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
  end
end
