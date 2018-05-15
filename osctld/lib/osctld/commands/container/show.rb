require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Show < Commands::Base
    handle :ct_show

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        ok({
          pool: ct.pool.name,
          id: ct.id,
          user: ct.user.name,
          group: ct.group.name,
          dataset: ct.dataset.name,
          rootfs: ct.rootfs,
          lxc_path: ct.lxc_home,
          lxc_dir: ct.lxc_dir,
          group_path: ct.cgroup_path,
          distribution: ct.distribution,
          version: ct.version,
          state: ct.state,
          init_pid: ct.init_pid,
          autostart: ct.autostart ? true : false,
          autostart_priority: ct.autostart && ct.autostart.priority,
          autostart_delay: ct.autostart && ct.autostart.delay,
          hostname: ct.hostname,
          dns_resolvers: ct.dns_resolvers,
          nesting: ct.nesting,
          log_file: ct.log_path,
        })
      end
    end
  end
end
