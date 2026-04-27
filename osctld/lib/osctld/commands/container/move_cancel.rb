require 'osctld/commands/container/local_transfer/cancel'

module OsCtld
  class Commands::Container::MoveCancel < Commands::Container::LocalTransfer::Cancel
    handle :ct_move_cancel

    protected

    def operation
      :move
    end
  end
end
