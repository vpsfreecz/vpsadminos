require 'osctld/commands/container/local_transfer/cancel'

module OsCtld
  class Commands::Container::CopyCancel < Commands::Container::LocalTransfer::Cancel
    handle :ct_copy_cancel

    protected

    def operation
      :copy
    end
  end
end
