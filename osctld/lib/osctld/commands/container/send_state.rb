require 'osctld/commands/base'
require 'open3'

module OsCtld
  class Commands::Container::SendState < Commands::Base
    handle :ct_send_state

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::Send

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct
      running = false

      manipulate(ct) do
        ct.exclusively do
          if !ct.migration_log || !ct.migration_log.can_continue?(:incremental)
            error!('invalid send sequence')
          end

          running = ct.state == :running
          call_cmd(Commands::Container::Stop, id: ct.id, pool: ct.pool.name)
        end

        snap = "osctl-send-incr-#{Time.now.to_i}"
        zfs(:snapshot, '-r', "#{ct.dataset}@#{snap}")

        ct.exclusively do
          ct.migration_log.snapshots << snap
          ct.save_config
        end

        progress("Syncing #{ct.dataset.relative_name}")
        send_dataset(ct, ct.dataset, snap)

        ct.dataset.descendants.each do |ds|
          progress("Syncing #{ds.relative_name}")
          send_dataset(ct, ds, snap)
        end

        ct.exclusively do
          ct.migration_log.state = :incremental
          ct.save_config

          if !ct.migration_log.can_continue?(:transfer)
            error!('invalid send sequence')
          end
        end

        progress('Starting on the target node')
        ret = system(
          *send_ssh_cmd(
            ct.pool.migration_key_chain,
            ct.migration_log.opts,
            ['receive', 'transfer', ct.id] + (running ? ['start'] : [])
          )
        )

        error!('transfer failed') if ret.nil? || $?.exitstatus != 0

        ct.exclusively do
          ct.migration_log.state = :transfer
          ct.save_config
        end

        ok
      end
    end

    protected
    def send_dataset(ct, ds, snap)
      stream = OsCtl::Lib::Zfs::Stream.new(ds, snap, ct.migration_log.snapshots[-2])
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
          ct.pool.migration_key_chain,
          ct.migration_log.opts,
          ['receive', 'incremental', ct.id, ds.relative_name, snap]
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
