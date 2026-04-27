require 'osctld/commands/container/local_transfer/base'

module OsCtld
  class Commands::Container::LocalTransfer::Sync < Commands::Container::LocalTransfer::Base
    def execute(ct)
      manipulate(ct) do
        log = ct.exclusively do
          ret = require_local_transfer_log!(ct)
          unless %i[base incremental].include?(ret.state) && ret.can_local_continue?(:incremental)
            error!('invalid local transfer sequence')
          end
          ret
        end

        target_ct(log)
        validate_dataset_layout!(ct)

        prev_snap = log.snapshots.last
        snap = snapshot_name(:incr)
        snapshot_datasets(log, snap)

        ct.exclusively do
          ct.local_transfer_log.snapshots << snap
          ct.save_config
        end

        log.opts.datasets.each do |pair|
          transfer_dataset(pair, snap, from_snapshot: prev_snap)
        end

        ct.exclusively do
          ct.local_transfer_log.state = :incremental
          ct.save_config
        end
      end

      ok
    end
  end
end
