require 'osctld/commands/base'
require 'open3'

module OsCtld
  class Commands::Container::MigrateCancel < Commands::Base
    handle :ct_migrate_cancel

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::Migration

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

        if ret.nil? || $?.exitstatus != 0 && !opts[:force]
          error!('cancel failed')
        end

        ct.each_dataset do |ds|
          ct.migration_log.snapshots.each do |snap|
            zfs(:destroy, nil, "#{ds}@#{snap}")
          end
        end

        ct.close_migration_log
      end

      ok
    end
  end
end
