require 'osctld/migration/commands/base'

module OsCtld
  class Migration::Commands::ReceiveCancel < Migration::Commands::Base
    handle :receive_cancel

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.exclusively do
        error!('this container is not staged') if ct.state != :staged

        if !ct.migration_log || !ct.migration_log.can_continue?(:cancel)
          error!('invalid migration sequence')
        end

        ct.migration_log.snapshots.each do |v|
          ds, snap = v
          zfs(:destroy, nil, "#{ds}@#{snap}")
        end

        call_cmd!(
          Commands::Container::Delete,
          id: ct.id,
          pool: ct.pool.name
        )

        ct.close_migration_log
      end

      ok
    end
  end
end
