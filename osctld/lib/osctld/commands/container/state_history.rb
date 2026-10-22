require 'osctld/commands/base'
require 'osctld/container_state_history'

module OsCtld
  class Commands::Container::StateHistory < Commands::Base
    handle :ct_state_history

    def execute
      error!('unknown history options') unless (opts.keys - %i[cli view pool id]).empty?

      begin
        data = OsCtld::ContainerStateHistory.export(
          view: opts.fetch(:view, 'timeline'), pool: opts[:pool], id: opts[:id]
        )
      rescue ArgumentError => e
        error!(e.message)
      end
      ok(data)
    end
  end
end
