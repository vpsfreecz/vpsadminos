require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  # Authorize one lifecycle-owned lxc-execute process. This is intentionally
  # distinct from the normal lxc-start callback so manual starts cannot borrow
  # a transient execution generation.
  class UserControl::Commands::CtLxcExecuteStart < UserControl::Commands::Base
    handle :ct_lxc_execute_start

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)
      unless opts[:client_pid] && opts[:pid].to_i == opts[:client_pid].to_i
        return error('lxc-execute process identity mismatch')
      end

      run_conf = lifecycle_run_conf(ct)
      return error('managed execution lifecycle run not found') unless run_conf

      unless ct.lifecycle.authorize_lxc_execution(
        run_conf.run_id,
        opts[:client_pid]
      )
        return error(
          'managed execution authorization denied; manual lxc-execute is unsupported'
        )
      end

      cgpath = run_conf.cgroup_path

      log(:debug, ct, "Reattaching lxc-execute, PID #{opts[:pid]} -> #{cgpath}")
      CGroup.mkpath_all(
        cgpath.split('/'),
        chown: ct.user.ugid,
        attach: true,
        leaf: false,
        pid: opts[:pid]
      )

      unless ct.lifecycle.activate_lxc_start(run_conf.run_id, opts[:client_pid])
        return error('managed execution authorization was superseded')
      end

      ok
    end
  end
end
