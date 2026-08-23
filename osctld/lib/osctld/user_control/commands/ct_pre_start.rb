require 'libosctl'
require 'osctld/commands/group/cgparam_apply'
require 'osctld/container/lifecycle_executor'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtPreStart < UserControl::Commands::Base
    handle :ct_pre_start

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      run_conf = lifecycle_run_conf(ct)
      return error('managed lifecycle run not found') unless run_conf
      unless ct.lifecycle.consume_pre_start(
        run_conf.run_id,
        client_pid: opts[:client_pid],
        callback_id: lifecycle_callback_id
      )
        return error('managed launch authorization missing; manual lxc-start is unsupported')
      end

      return error('managed lifecycle run changed') unless ct.starting(run_conf.run_id)

      # Mount datasets
      run_conf.mount(force: true)

      # Load AppArmor profile
      ct.apparmor.setup(run_conf) if AppArmor.enabled?

      # Configure CGroups
      ret = call_cmd(
        Commands::Group::CGParamApply,
        name: ct.group.name,
        pool: ct.pool.name,
        manipulation_lock: 'ignore',
        skip_cpuset: true,
        skip_cpu_bandwidth: true
      )
      return ret unless ret[:status]

      begin
        ct.cgparams.apply_for_start(
          run_id: run_conf.run_id,
          keep_going: ct.running?
        ) do |subsystem|
          ct.abs_apply_cgroup_path(subsystem)
        end
        ct.cgparams.apply_cpuset_for_start(run_id: run_conf.run_id)
      rescue CGroup::CpusetPolicy::Error => e
        return error(e.message)
      end

      # Configure devices cgroup
      ct.devices.apply

      # Prepared shared mount directory
      ct.mounts.shared_dir.create

      # Setup start menu
      ct.setup_start_menu

      # User-defined hook
      Hook.run(ct, :pre_start)

      completed = ct.lifecycle.complete_pre_start(
        run_conf.run_id,
        callback_id: lifecycle_callback_id
      )
      return error('managed launch was superseded during pre-start') unless completed

      effect_id = completed.last
      if effect_id
        Container::LifecycleExecutor.release(ct.pool, :start, effect_id)
      end

      ok
    rescue HookFailed => e
      error(e.message)
    end
  end
end
