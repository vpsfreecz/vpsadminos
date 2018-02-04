module OsCtld
  class Commands::Container::MigrateSync < Commands::Base
    handle :ct_migrate_sync

    include Utils::Log
    include Utils::System
    include Utils::Zfs
    include Utils::Migration

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

      stream = Zfs::Stream.new(ct.dataset, snap)
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
          ['receive', 'base', ct.id, snap]
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
        ct.migration_log.state = :base
        ct.save_config
      end

      ok
    end
  end
end
