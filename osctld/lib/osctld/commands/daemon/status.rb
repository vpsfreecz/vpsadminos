require 'osctld/commands/base'

module OsCtld
  class Commands::Daemon::Status < Commands::Base
    handle :daemon_status

    def execute
      ok(Daemon.get.status)
    end
  end
end
