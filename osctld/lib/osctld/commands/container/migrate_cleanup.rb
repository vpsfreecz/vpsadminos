require 'osctld/commands/base'

module OsCtld
  class Commands::Container::MigrateCleanup < Commands::Base
    handle :ct_migrate_cleanup

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

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
          ct.each_dataset do |ds|
            ct.migration_log.snapshots.each do |snap|
              zfs(:destroy, nil, "#{ds}@#{snap}")
            end
          end
        end

        ct.close_migration_log
        ok
      end
    end
  end
end
