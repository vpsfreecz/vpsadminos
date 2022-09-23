require 'osctld/commands/base'

module OsCtld
  class Commands::Self::AbortShutdown < Commands::Base
    handle :self_abort_shutdown

    def execute
      Daemon.get.abort_shutdown
      ok
    end
  end
end
