require 'osctld/commands/container/local_transfer/config'

module OsCtld
  class Commands::Container::MoveConfig < Commands::Container::LocalTransfer::Config
    handle :ct_move_config

    protected

    def operation
      :move
    end
  end
end
