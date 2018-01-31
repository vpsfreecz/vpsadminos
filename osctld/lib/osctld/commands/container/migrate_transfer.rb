require 'open3'

module OsCtld
  class Commands::Container::MigrateTransfer < Commands::Base
    handle :ct_migrate_transfer

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct
      running = false

      ct.exclusively do
        if !ct.migration_log || !ct.migration_log.can_continue?(:incremental)
          error!('invalid migration sequence')
        end

        running = ct.state == :running
        call_cmd(Commands::Container::Stop, id: ct.id, pool: ct.pool.name)
      end

      snap = "osctl-migrate-incr-#{Time.now.to_i}"
      zfs(:snapshot, nil, "#{ct.dataset}@#{snap}")

      ct.exclusively do
        ct.migration_log.snapshots << snap
        ct.save_config
      end

      m_opts = ct.migration_log.opts

      Open3.pipeline(
        [
          'zfs', 'send', '-c',
          '-I', ct.migration_log.snapshots[-2],
          "#{ct.dataset}@#{snap}"
        ],
        [
          'ssh',
          '-o', 'StrictHostKeyChecking=no',
          '-T',
          '-p', m_opts[:port].to_s,
          '-i', ct.pool.migration_key_chain.private_key_path,
          '-l', 'migration',
          m_opts[:dst],
          'receive', 'incremental', ct.id, snap
        ],
      ).each do |status|
        next if status.exitstatus == 0
        error!('sync failed')
      end

      ct.exclusively do
        ct.migration_log.state = :incremental
        ct.save_config

        if !ct.migration_log.can_continue?(:transfer)
          error!('invalid migration sequence')
        end
      end

      system(
        'ssh',
        '-o', 'StrictHostKeyChecking=no',
        '-T',
        '-p', m_opts[:port].to_s,
        '-i', ct.pool.migration_key_chain.private_key_path,
        '-l', 'migration',
        m_opts[:dst],
        'receive', 'transfer', ct.id, *(running ? ['start'] : [])
      )

      ct.exclusively do
        ct.migration_log.state = :transfer
        ct.save_config
      end

      ok
    end
  end
end
