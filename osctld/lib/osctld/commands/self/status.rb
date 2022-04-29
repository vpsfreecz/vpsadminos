require 'osctld/commands/base'

module OsCtld
  class Commands::Self::Status < Commands::Base
    handle :self_status

    def execute
      d = Daemon.get

      ok({
        started_at: d.started_at.to_i,
        initialized: d.initialized,
      })
    end
  end
end
