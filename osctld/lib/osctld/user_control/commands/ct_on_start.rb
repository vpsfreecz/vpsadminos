require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtOnStart < UserControl::Commands::Base
    handle :ct_on_start

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      run_conf = lifecycle_run_conf(ct)
      return error('managed lifecycle run not found') unless run_conf

      # LXC creates the namespaced cgroup root after the pre-start hook. Apply
      # the policy again from start-host, while this exact callback is leased,
      # so the new inner cgroup receives an explicit cpuset mask.
      begin
        ct.cgparams.apply_cpuset_for_start(run_id: run_conf.run_id)
      rescue CGroup::CpusetPolicy::Error => e
        return error(e.message)
      end

      # Configure the system
      DistConfig.run(run_conf, :start)

      Hook.run(ct, :on_start)
      ok
    rescue HookFailed => e
      error(e.message)
    end
  end
end
