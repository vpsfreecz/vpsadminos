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

      if ct.send_log.opts.from_snapshot && ct.send_log.opts.preexisting_datasets
        send_snapshot(ct, ds, base_snap, base_snap, ct.send_log.opts.from_snapshot)

      elsif ct.send_log.opts.from_snapshot && !ct.send_log.opts.preexisting_datasets
        send_snapshot(ct, ds, base_snap, ct.send_log.opts.from_snapshot)
        send_snapshot(ct, ds, base_snap, base_snap, ct.send_log.opts.from_snapshot)

      elsif ct.send_log.opts.snapshots
        snaps = ds.snapshots
        send_snapshot(ct, ds, base_snap, snaps.first.snapshot)

        if snaps.count > 1
          send_snapshot(ct, ds, base_snap, snaps.last.snapshot, snaps.first.snapshot)
        end
      else
        send_snapshot(ct, ds, base_snap, base_snap)
      end
    end

    def send_snapshot(ct, ds, base_snap, snap, from_snap = nil)
      stream = OsCtl::Lib::Zfs::Stream.new(
        ds,
        snap,
        from_snap,
        intermediary: ct.send_log.opts.snapshots
      )
      stream.progress do |total, _transfered, changed|
        progress(type: :progress, data: {
          time: Time.now.to_i,
          size: stream.size,
          transfered: total,
          changed:
        })
      end

      mbuf_opts = Daemon.get.config.send_receive.send_mbuffer.as_hash_options
      r, send = stream.spawn_with_mbuffer(**mbuf_opts)
      pid = Process.spawn(
        *send_ssh_cmd(
          ct.pool.send_receive_key_chain,
          ct.send_log.opts,
          [
            'receive', from_snap ? 'incremental' : 'base',
            ct.send_log.token, ds.relative_name
          ] + (base_snap == snap ? [base_snap] : [])
        ),
        in: r
      )
      r.close

      send_status = stream.monitor(send)

      _, ssh_status = Process.wait2(pid)

      return unless send_status.exitstatus != 0 || ssh_status.exitstatus != 0

      error!('sync failed')
    end
  end
end
