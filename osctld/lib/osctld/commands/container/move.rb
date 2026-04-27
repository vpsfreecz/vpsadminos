require 'osctld/commands/logged'
require 'osctld/commands/container/move_config'
require 'osctld/commands/container/move_rootfs'
require 'osctld/commands/container/move_state'
require 'osctld/commands/container/move_cleanup'

module OsCtld
  class Commands::Container::Move < Commands::Logged
    handle :ct_move

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        progress(type: :step, title: 'Preparing move')
        call_cmd!(Commands::Container::MoveConfig, **config_opts(ct))

        progress(type: :step, title: 'Copying rootfs')
        call_cmd!(Commands::Container::MoveRootfs, id: ct.id, pool: ct.pool.name)

        progress(type: :step, title: 'Moving state')
        call_cmd!(
          Commands::Container::MoveState,
          id: ct.id,
          pool: ct.pool.name,
          start: opts.fetch(:start, true)
        )

        progress(type: :step, title: 'Cleaning up')
        call_cmd!(Commands::Container::MoveCleanup, id: ct.id, pool: ct.pool.name)
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
        network_interfaces: true
      }
    end
  end
end
