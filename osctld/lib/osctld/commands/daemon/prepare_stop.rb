require 'osctld/commands/base'

module OsCtld
  class Commands::Daemon::PrepareStop < Commands::Base
    handle :daemon_prepare_stop

    def execute
      if Daemon.get.prepare_stop
        ok(Daemon.get.status)
      else
        error('container lifecycle drain did not complete safely')
      end
    end
  end
end
