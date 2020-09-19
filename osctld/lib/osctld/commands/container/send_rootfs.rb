require 'osctld/commands/base'

module OsCtld
  class Commands::Container::SendRootfs < Commands::Base
    handle :ct_send_rootfs

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::Send

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      manipulate(ct) do
        ct.exclusively do
          if !ct.send_log || !ct.send_log.can_send_continue?(:base)
            error!('invalid send sequence')
          end
        end

        snap = "osctl-send-base-#{Time.now.to_i}"
        zfs(:snapshot, '-r', "#{ct.dataset}@#{snap}")

        ct.exclusively do
          ct.send_log.snapshots << snap
          ct.save_config
        end

        send_dataset(ct, ct.dataset, snap)
        ct.dataset.descendants.each do |ds|
          send_dataset(ct, ds, snap)
        end

        ct.exclusively do
          ct.send_log.state = :base
          ct.save_config
        end
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
      stream = OsCtl::Lib::Zfs::Stream.new(ds, snap.snapshot, from_snap && from_snap.snapshot)
      stream.progress do |total, transfered, changed|
        progress(type: :progress, data: {
          time: Time.now.to_i,
          size: stream.size,
          transfered: total,
          changed: changed,
        })
      end

      r, send = stream.spawn
      pid = Process.spawn(
        *send_ssh_cmd(
          ct.pool.send_receive_key_chain,
          ct.send_log.opts,
          [
            'receive', from_snap ? 'incremental' : 'base',
            ct.send_log.token, ds.relative_name
          ] + (base_snap == snap.snapshot ? [base_snap] : [])
        ),
        in: r
      )
      r.close

      send_status = stream.monitor(send)

      _, ssh_status = Process.wait2(pid)

      if send_status.exitstatus != 0 || ssh_status.exitstatus != 0
        error!('sync failed')
      end
    end
  end
end
