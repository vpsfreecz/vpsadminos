require 'osctld/commands/logged'
require 'osctld/commands/container/copy_config'
require 'osctld/commands/container/copy_rootfs'
require 'osctld/commands/container/copy_state'
require 'osctld/commands/container/copy_cleanup'

module OsCtld
  class Commands::Container::Copy < Commands::Logged
    handle :ct_copy

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        progress(type: :step, title: 'Preparing copy')
        call_cmd!(Commands::Container::CopyConfig, **config_opts(ct))

        progress(type: :step, title: 'Copying rootfs')
        call_cmd!(Commands::Container::CopyRootfs, id: ct.id, pool: ct.pool.name)

        progress(type: :step, title: 'Copying state')
        call_cmd!(
          Commands::Container::CopyState,
          id: ct.id,
          pool: ct.pool.name,
          consistent: opts.fetch(:consistent, true),
          restart: opts.fetch(:restart, true)
        )

        progress(type: :step, title: 'Cleaning up')
        call_cmd!(Commands::Container::CopyCleanup, id: ct.id, pool: ct.pool.name)
      end

      ok
    end

    protected

    def config_opts(ct)
      {
        id: ct.id,
        pool: ct.pool.name,
        target_pool: opts[:target_pool],
        target_id: opts[:target_id],
        target_user: opts[:target_user],
        target_group: opts[:target_group],
        target_dataset: opts[:target_dataset],
        network_interfaces: opts[:network_interfaces],
        from_snapshot: opts[:from_snapshot]
      }
    end
  end
end
