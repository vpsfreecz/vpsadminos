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
      zfs(:snapshot, '-r', "#{ct.dataset}@#{snap}")

      ct.exclusively do
        ct.migration_log.snapshots << snap
        ct.save_config
      end

      send_dataset(ct, ct.dataset, snap)
      ct.dataset.descendants.each do |ds|
        send_dataset(ct, ds, snap)
      end

      ct.exclusively do
        ct.migration_log.state = :base
        ct.save_config
      end

      ok
    end

    protected
    def send_dataset(ct, ds, base_snap)
      progress("Syncing #{ds.relative_name}")

      snaps = ds.snapshots
      send_snapshot(ct, ds, base_snap, snaps.first)
      send_snapshot(ct, ds, base_snap, snaps.last, snaps.first) if snaps.count > 1
    end

    def send_snapshot(ct, ds, base_snap, snap, from_snap = nil)
      stream = Zfs::Stream.new(ds, snap.snapshot, from_snap && from_snap.snapshot)
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
          [
            'receive', from_snap ? 'incremental' : 'base',
            ct.id, ds.relative_name
          ] + (base_snap == snap.snapshot ? [base_snap] : [])
        ),
        in: r
      )
      r.close
      stream.monitor(send)

      _, status = Process.wait2(pid)

      error!('sync failed') if status.exitstatus != 0
    end
  end
end
