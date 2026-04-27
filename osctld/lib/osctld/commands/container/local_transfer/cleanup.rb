require 'osctld/commands/container/local_transfer/base'

module OsCtld
  class Commands::Container::LocalTransfer::Cleanup < Commands::Container::LocalTransfer::Base
    def execute(ct)
      manipulate(ct) do
        log = ct.exclusively do
          ret = require_local_transfer_log!(ct)
          unless %i[transfer cleanup].include?(ret.state) && ret.can_local_continue?(:cleanup)
            error!('invalid local transfer sequence')
          end
          ret.state = :cleanup
          ct.save_config
          ret
        end

        destroy_local_transfer_snapshots(log)
        cleanup_after_snapshots(ct, log)
      end

      ok
    end

    protected

    def cleanup_after_snapshots(ct, _log)
      ct.close_local_transfer_log
    end
  end
end
