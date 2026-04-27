require 'osctld/commands/container/local_transfer/cleanup'

module OsCtld
  class Commands::Container::MoveCleanup < Commands::Container::LocalTransfer::Cleanup
    handle :ct_move_cleanup

    protected

    def operation
      :move
    end

    def cleanup_after_snapshots(ct, _log)
      call_cmd!(
        Commands::Container::Delete,
        id: ct.id,
        pool: ct.pool.name,
        force: true
      )
    end
  end
end
