require 'osctld/commands/container/local_transfer/state'

module OsCtld
  class Commands::Container::CopyState < Commands::Container::LocalTransfer::State
    handle :ct_copy_state

    protected

    def operation
      :copy
    end

    def stop_source_for_state?(running)
      running && opts.fetch(:consistent, true)
    end

    def after_state_snapshot(ct, running, stopped)
      return unless stopped && opts.fetch(:restart, true) && running

      call_cmd!(
        Commands::Container::Start,
        id: ct.id,
        pool: ct.pool.name,
        force: true
      )
    end
  end
end
