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
      unless opts[:client_pid] && opts[:pid].to_i == opts[:client_pid].to_i
        return error('wrapper process identity mismatch')
      end

      run_conf = lifecycle_run_conf(ct)
      return error('managed lifecycle run not found') unless run_conf
      unless ct.lifecycle.authorize_lxc_start(run_conf.run_id, opts[:client_pid])
        return error('managed launch authorization denied; manual lxc-start is unsupported')
      end

      # Move the calling wrapper to user-owned cgroup, which will then be used
      # by LXC
      cgpath = run_conf.cgroup_path

      log(:debug, ct, "Reattaching wrapper, PID #{opts[:pid]} -> #{cgpath}")
      CGroup.mkpath_all(
        cgpath.split('/'),
        chown: ct.user.ugid,
        attach: true,
        leaf: false,
        pid: opts[:pid]
      )

      # Reset oom_score_adj of the calling process. The reset has to come from
      # a process with CAP_SYS_RESOURCE (which osctld is), so that
      # oom_score_adj_min is changed and container users cannot freely set
      # oom_score_adj to -1000.
      log(:debug, ct, "Set /proc/#{opts[:pid]}/oom_score_adj=0")
      File.write(File.join('/proc', opts[:pid].to_s, 'oom_score_adj'), '0')

      unless ct.lifecycle.activate_lxc_start(run_conf.run_id, opts[:client_pid])
        return error('managed launch authorization was superseded')
      end

      ok
    end
  end
end
