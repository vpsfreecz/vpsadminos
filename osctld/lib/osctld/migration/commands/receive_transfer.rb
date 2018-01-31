module OsCtld
  class Migration::Commands::Transfer < Migration::Commands::Base
    handle :receive_transfer

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.exclusively do
        error!('this container is not staged') if ct.state != :staged

        if !ct.migration_log || !ct.migration_log.can_continue?(:transfer)
          error!('invalid migration sequence')
        end

        ct.state = :complete

        call_cmd!(
          Commands::Container::Start,
          id: ct.id,
          pool: ct.pool.name,
          force: true
        ) if opts[:start]

        ct.migration_log.snapshots.each do |snap|
          zfs(:destroy, nil, "#{ct.dataset}@#{snap}")
        end

        ct.close_migration_log
      end

      ok
    end
  end
end
