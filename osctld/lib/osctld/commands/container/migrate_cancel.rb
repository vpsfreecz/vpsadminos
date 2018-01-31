require 'open3'

module OsCtld
  class Commands::Container::MigrateCancel < Commands::Base
    handle :ct_migrate_cancel

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.exclusively do
        if !ct.migration_log || !ct.migration_log.can_continue?(:cancel)
          error!('invalid migration sequence')
        end

        m_opts = ct.migration_log.opts

        system(
          'ssh',
          '-o', 'StrictHostKeyChecking=no',
          '-T',
          '-p', m_opts[:port].to_s,
          '-i', ct.pool.migration_key_chain.private_key_path,
          '-l', 'migration',
          m_opts[:dst],
          'receive', 'cancel', ct.id
        )

        ct.migration_log.snapshots.each do |snap|
          zfs(:destroy, nil, "#{ct.dataset}@#{snap}")
        end

        ct.close_migration_log
      end

      ok
    end
  end
end
