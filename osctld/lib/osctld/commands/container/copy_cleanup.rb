require 'osctld/commands/container/local_transfer/cleanup'

module OsCtld
  class Commands::Container::CopyCleanup < Commands::Container::LocalTransfer::Cleanup
    handle :ct_copy_cleanup

    protected

    def operation
      :copy
    end
  end
end
