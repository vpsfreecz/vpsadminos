require 'osctld/commands/container/local_transfer/rootfs'

module OsCtld
  class Commands::Container::MoveRootfs < Commands::Container::LocalTransfer::Rootfs
    handle :ct_move_rootfs

    protected

    def operation
      :move
    end
  end
end
