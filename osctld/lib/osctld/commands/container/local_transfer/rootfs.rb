require 'osctld/commands/container/local_transfer/base'

module OsCtld
  class Commands::Container::LocalTransfer::Rootfs < Commands::Container::LocalTransfer::Base
    def execute(ct)
      manipulate(ct) do
        log = ct.exclusively do
          ret = require_local_transfer_log!(ct)
          error!('invalid local transfer sequence') unless ret.can_local_continue?(:base)
          ret
        end

        target_ct(log)
        validate_dataset_layout!(ct)

        snap = snapshot_name(:base)
        snapshot_datasets(log, snap)

        ct.exclusively do
          ct.local_transfer_log.snapshots << snap
          ct.save_config
        end

        transfer_rootfs_snapshots(log, snap)

        ct.exclusively do
          ct.local_transfer_log.state = :base
          ct.save_config
        end
      end

      ok
    end

    protected

    def transfer_rootfs_snapshots(log, base_snap)
      from_snapshot = log.opts.from_snapshot

      log.opts.datasets.each do |pair|
        if from_snapshot
          transfer_dataset(pair, from_snapshot)
          transfer_dataset(pair, base_snap, from_snapshot:)
        else
          transfer_dataset(pair, base_snap)
        end
      end
    end
  end
end
