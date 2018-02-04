module OsCtld
  class Commands::Container::MigrateNow < Commands::Base
    handle :ct_migrate_now

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      progress(type: :step, title: 'Staging migration')
      call_cmd!(
        Commands::Container::MigrateStage,
        id: ct.id,
        pool: ct.pool.name,
        dst: opts[:dst],
        port: opts[:port]
      )

      progress(type: :step, title: 'Copying base streams')
      call_cmd!(
        Commands::Container::MigrateSync,
        id: ct.id,
        pool: ct.pool.name
      )

      progress(type: :step, title: 'Transfering container')
      call_cmd!(
        Commands::Container::MigrateTransfer,
        id: ct.id,
        pool: ct.pool.name
      )

      progress(type: :step, title: 'Cleaning up')
      call_cmd!(
        Commands::Container::MigrateCleanup,
        id: ct.id,
        pool: ct.pool.name,
        delete: opts[:delete]
      )
    end
  end
end
