require 'vpsadminos-converter/vz6/migrator/base'

module VpsAdminOS::Converter
  class Vz6::Migrator::Zfs < Vz6::Migrator::Base
    def sync(&block)
      self.progress_handler = block

      if opts[:zfs_subdir] != 'private'
        fail 'only zfs-subdir=private is implemented'
      end

      snap = "converter-migrate-base-#{Time.now.to_i}"
      zfs(:snapshot, '-r', "#{state.target_ct.dataset}@#{snap}")

      state.set_step(:sync)
      state.snapshots << snap
      state.save

      state.target_ct.datasets.each do |ds|
        send_dataset(state.target_ct, ds, snap)
      end
    end

    def transfer(&block)
      self.progress_handler = block

      if opts[:zfs_subdir] != 'private'
        fail 'only zfs-subdir=private is implemented'
      end

      # Stop the container
      running = vz_ct.running?
      syscmd("vzctl stop #{vz_ct.ctid}")

      # Final sync
      snap = "converter-migrate-incr-#{Time.now.to_i}"
      zfs(:snapshot, '-r', "#{target_ct.dataset}@#{snap}")

      state.snapshots << snap
      state.save

      state.target_ct.datasets.each do |ds|
        send_dataset_incr(target_ct, ds, snap, state.snapshots[-2])
      end

      # Transfer to dst
      transfer_container(running)
    end

    def cleanup(cmd_opts)
      target_ct.datasets.each do |ds|
        state.snapshots.each do |snap|
          zfs(:destroy, nil, "#{ds}@#{snap}")
        end
      end

      if cmd_opts[:delete]
        syscmd("vzctl destroy #{vz_ct.ctid}")
        zfs(:destroy, '-r', target_ct.dataset)
      end

      state.destroy
    end

    def cancel(cmd_opts)
      cancel_remote(cmd_opts[:force])
      state.destroy
    end

    protected
    def send_dataset(ct, ds, base_snap)
      progress(:step, "Syncing #{ds.relative_name}")

      snaps = ds.snapshots
      send_snapshot(ct, ds, base_snap, snaps.first.snapshot)
      send_snapshot(
        ct,
        ds,
        base_snap,
        snaps.last.snapshot,
        snaps.first.snapshot
      ) if snaps.count > 1
    end

    def send_dataset_incr(ct, ds, incr_snap, from_snap)
      progress(:step, "Syncing #{ds.relative_name}")
      send_snapshot(ct, ds, incr_snap, incr_snap, from_snap)
    end

    def send_snapshot(ct, ds, base_snap, snap, from_snap = nil)
      stream = OsCtl::Lib::Zfs::Stream.new(
        ds,
        snap,
        from_snap,
        compressed: opts[:zfs_compressed_send]
      )
      stream.progress do |total, transfered, changed|
        progress(:transfer, [stream.size, total])
      end

      r, send = stream.spawn
      pid = Process.spawn(
        *migrate_ssh_cmd(
          nil,
          opts,
          [
            'receive', from_snap ? 'incremental' : 'base',
            ct.id, ds.relative_name
          ] + (base_snap == snap ? [base_snap] : [])
        ),
        in: r
      )
      r.close
      stream.monitor(send)

      _, status = Process.wait2(pid)

      fail 'sync failed' if status.exitstatus != 0
    end
  end
end
