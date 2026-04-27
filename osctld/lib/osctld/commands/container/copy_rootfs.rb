require 'osctld/commands/container/local_transfer/rootfs'

module OsCtld
  class Commands::Container::CopyRootfs < Commands::Container::LocalTransfer::Rootfs
    handle :ct_copy_rootfs

    protected

    def operation
      :copy
    end
  end
end
