require 'open3'

module OsCtld
  class Commands::Container::MigrateCancel < Commands::Base
    handle :ct_migrate_cancel

    include Utils::Log
    include Utils::System
    include Utils::Zfs
    include Utils::Migration

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.exclusively do
        if !ct.migration_log || !ct.migration_log.can_continue?(:cancel)
          error!('invalid migration sequence')
        end

        ret = system(
          *migrate_ssh_cmd(
            ct.pool.migration_key_chain,
            ct.migration_log.opts,
            ['receive', 'cancel', ct.id]
          )
        )

        if ret.nil? || $?.exitstatus != 0
          error!('cancel failed')
        end

        ct.migration_log.snapshots.each do |snap|
          zfs(:destroy, nil, "#{ct.dataset}@#{snap}")
        end

        ct.close_migration_log
      end

      ok
    end
  end
end
