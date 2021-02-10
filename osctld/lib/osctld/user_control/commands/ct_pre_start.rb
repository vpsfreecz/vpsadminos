require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtPreStart < UserControl::Commands::Base
    handle :ct_pre_start

    include OsCtl::Lib::Utils::Log

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      ct.starting

      # Mount datasets
      ct.run_conf.mount(force: true)

      # Load AppArmor profile
      ct.apparmor.setup

      # Configure CGroups
      ret = call_cmd(
        Commands::Container::CGParamApply,
        id: ct.id,
        pool: ct.pool.name,
        manipulation_lock: 'ignore',
      )
      return ret unless ret[:status]

      # Configure devices cgroup
      ct.devices.apply

      # Prepared shared mount directory
      ct.mounts.shared_dir.create

      # Configure hostname
      DistConfig.run(ct.run_conf, :set_hostname) if ct.hostname

      # Configure network within the CT
      ct.dist_configure_network

      # DNS resolvers
      DistConfig.run(ct.run_conf, :dns_resolvers) if ct.dns_resolvers

      # User-defined hook
      Container::Hook.run(ct, :pre_start)

      ok

    rescue HookFailed => e
      error(e.message)
    end
  end
end
