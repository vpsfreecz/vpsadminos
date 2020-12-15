require 'osctld/commands/base'

module OsCtld
  class Commands::Container::SendNow < Commands::Base
    handle :ct_send_now

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      manipulate(ct) do
        progress(type: :step, title: 'Sending config')
        call_cmd!(
          Commands::Container::SendConfig,
          id: ct.id,
          pool: ct.pool.name,
          dst: opts[:dst],
          port: opts[:port],
          passphrase: opts[:passphrase],
          as_id: opts[:as_id],
          to_pool: opts[:to_pool],
          network_interfaces: opts[:network_interfaces],
          snapshots: opts[:snapshots],
        )

        progress(type: :step, title: 'Sending rootfs')
        call_cmd!(
          Commands::Container::SendRootfs,
          id: ct.id,
          pool: ct.pool.name,
        )

        progress(type: :step, title: 'Sending state')
        call_cmd!(
          Commands::Container::SendState,
          id: ct.id,
          pool: ct.pool.name,
          clone: opts[:clone],
          restart: opts[:restart],
          start: opts[:start],
        )

        progress(type: :step, title: 'Cleaning up')
        call_cmd!(
          Commands::Container::SendCleanup,
          id: ct.id,
          pool: ct.pool.name,
        )
      end
    end
  end
end
