require 'open3'

module OsCtld
  class Commands::Container::MigrateSync < Commands::Base
    handle :ct_migrate_sync

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.exclusively do
        if !ct.migration_log || !ct.migration_log.can_continue?(:base)
          error!('invalid migration sequence')
        end
      end

      snap = "osctl-migrate-base-#{Time.now.to_i}"
      zfs(:snapshot, nil, "#{ct.dataset}@#{snap}")

      ct.exclusively do
        ct.migration_log.snapshots << snap
        ct.save_config
      end

      m_opts = ct.migration_log.opts

      Open3.pipeline(
        [
          'zfs', 'send', '-c', "#{ct.dataset}@#{snap}"
        ],
        [
          'ssh',
          '-o', 'StrictHostKeyChecking=no',
          '-T',
          '-p', (m_opts[:port]).to_s,
          '-i', ct.pool.migration_key_chain.private_key_path,
          '-l', 'migration',
          m_opts[:dst],
          'receive', 'base', ct.id, snap
        ],
      ).each do |status|
        next if status.exitstatus == 0
        error!('sync failed')
      end

      ct.exclusively do
        ct.migration_log.state = :base
        ct.save_config
      end

      ok
    end
  end
end
