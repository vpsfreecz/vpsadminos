module OsCtld
  class Commands::Container::MigrateCleanup < Commands::Base
    handle :ct_migrate_cleanup

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.exclusively do
        if !ct.migration_log || !ct.migration_log.can_continue?(:cleanup)
          error!('invalid migration sequence')
        end

        if opts[:delete]
          call_cmd!(
            Commands::Container::Delete,
            pool: ct.pool.name,
            id: ct.id
          )

        else
          ct.migration_log.snapshots.each do |snap|
            zfs(:destroy, nil, "#{ct.dataset}@#{snap}")
          end
        end

        ct.close_migration_log
        ok
      end
    end
  end
end
