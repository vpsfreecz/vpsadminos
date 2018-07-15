require 'osctld/commands/base'

module OsCtld
  class Commands::Self::Ping < Commands::Base
    handle :self_ping

    def execute
      ok('pong')
    end
  end
end
