require 'osctld/commands/base'

module OsCtld
  class Commands::Container::SendSync < Commands::Base
    handle :ct_send_sync

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::Send

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct
      running = false

      manipulate(ct) do
        ct.exclusively do
          if !ct.send_log || !ct.send_log.can_send_continue?(:incremental)
            error!('invalid send sequence')
          end
        end

        snap = "osctl-send-incr-#{Time.now.to_i}"
        zfs(:snapshot, '-r', "#{ct.dataset}@#{snap}")

        ct.exclusively do
          ct.send_log.snapshots << snap
          ct.save_config
        end

        progress("Syncing #{ct.dataset.relative_name}")
        send_dataset(ct, ct.dataset, snap)

        ct.dataset.descendants.each do |ds|
          progress("Syncing #{ds.relative_name}")
          send_dataset(ct, ds, snap)
        end

        ct.exclusively do
          ct.send_log.state = :incremental
          ct.save_config
        end

        ok
      end
    end

    protected
    def send_dataset(ct, ds, snap)
      stream = OsCtl::Lib::Zfs::Stream.new(ds, snap, ct.send_log.snapshots[-2])
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
          ['receive', 'incremental', ct.send_log.opts.ctid, ds.relative_name, snap]
        ),
        in: r
      )
      r.close
      stream.monitor(send)

      _, status = Process.wait2(pid)

      if status.exitstatus != 0
        error!('sync failed')
      end
    end
  end
end
