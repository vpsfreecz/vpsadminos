require 'osctld/commands/container/local_transfer/config'

module OsCtld
  class Commands::Container::CopyConfig < Commands::Container::LocalTransfer::Config
    handle :ct_copy_config

    protected

    def operation
      :copy
    end
  end
end
