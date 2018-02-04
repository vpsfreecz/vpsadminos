require 'open3'

module OsCtld
  class Commands::Container::MigrateTransfer < Commands::Base
    handle :ct_migrate_transfer

    include Utils::Log
    include Utils::System
    include Utils::Zfs
    include Utils::Migration

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

      stream = Zfs::Stream.new(ct.dataset, snap, ct.migration_log.snapshots[-2])
      stream.progress do |total, changed|
        progress(type: :progress, data: {
          time: Time.now.to_i,
          size: stream.size,
          transfered: total,
          changed: changed,
        })
      end

      r, send = stream.spawn
      pid = Process.spawn(
        *migrate_ssh_cmd(
          ct.pool.migration_key_chain,
          ct.migration_log.opts,
          ['receive', 'incremental', ct.id, snap]
        ),
        in: r
      )
      r.close
      stream.monitor(send)

      _, status = Process.wait2(pid)

      if status.exitstatus != 0
        error!('sync failed')
      end

      ct.exclusively do
        ct.migration_log.state = :incremental
        ct.save_config

        if !ct.migration_log.can_continue?(:transfer)
          error!('invalid migration sequence')
        end
      end

      ret = system(
        *migrate_ssh_cmd(
          ct.pool.migration_key_chain,
          ct.migration_log.opts,
          ['receive', 'transfer', ct.id] + (running ? ['start'] : [])
        )
      )

      if ret.nil? || $?.exitstatus != 0
        error!('transfer failed')
      end

      ct.exclusively do
        ct.migration_log.state = :transfer
        ct.save_config
      end

      ok
    end
  end
end
