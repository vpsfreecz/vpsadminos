require 'osctld/commands/base'

module OsCtld
  class Commands::Container::SendNow < Commands::Base
    handle :ct_send_now

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      progress(type: :step, title: 'Sending config')
      call_cmd!(
        Commands::Container::SendConfig,
        id: ct.id,
        pool: ct.pool.name,
        dst: opts[:dst],
        port: opts[:port],
        as_id: opts[:as_id],
      )

      progress(type: :step, title: 'Sending rootfs')
      call_cmd!(
        Commands::Container::SendRootfs,
        id: ct.id,
        pool: ct.pool.name
      )

      progress(type: :step, title: 'Sending state')
      call_cmd!(
        Commands::Container::SendState,
        id: ct.id,
        pool: ct.pool.name
      )

      progress(type: :step, title: 'Cleaning up')
      call_cmd!(
        Commands::Container::SendCleanup,
        id: ct.id,
        pool: ct.pool.name,
        delete: opts[:delete]
      )
    end
  end
end
