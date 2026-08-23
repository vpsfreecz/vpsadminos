require 'osctld/commands/base'

module OsCtld
  class Commands::Daemon::Resume < Commands::Base
    handle :daemon_resume

    def execute
      Daemon.get.resume ? ok(Daemon.get.status) : error('daemon cannot be resumed')
    end
  end
end
