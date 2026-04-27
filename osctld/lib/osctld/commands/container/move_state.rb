require 'osctld/commands/container/local_transfer/state'

module OsCtld
  class Commands::Container::MoveState < Commands::Container::LocalTransfer::State
    handle :ct_move_state

    protected

    def operation
      :move
    end

    def stop_source_for_state?(running)
      running
    end

    def after_target_complete(log, running)
      start_target!(log) if running && opts.fetch(:start, true)
    end
  end
end
