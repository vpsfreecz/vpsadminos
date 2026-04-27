require 'osctld/commands/container/local_transfer/sync'

module OsCtld
  class Commands::Container::MoveSync < Commands::Container::LocalTransfer::Sync
    handle :ct_move_sync

    protected

    def operation
      :move
    end
  end
end
