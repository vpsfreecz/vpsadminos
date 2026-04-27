require 'osctld/commands/container/local_transfer/base'

module OsCtld
  class Commands::Container::LocalTransfer::Cancel < Commands::Container::LocalTransfer::Base
    def execute(ct)
      manipulate(ct) do
        log = ct.exclusively do
          ret = require_local_transfer_log!(ct)
          error!('invalid local transfer sequence') unless ret.can_local_cancel?(opts[:force])
          ret
        end

        destroy_local_transfer_snapshots(log)
        cleanup_target_container!(log)
        ct.close_local_transfer_log
      end

      ok
    end
  end
end
