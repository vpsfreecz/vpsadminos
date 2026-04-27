require 'osctld/commands/container/local_transfer/sync'

module OsCtld
  class Commands::Container::CopySync < Commands::Container::LocalTransfer::Sync
    handle :ct_copy_sync

    protected

    def operation
      :copy
    end
  end
end
