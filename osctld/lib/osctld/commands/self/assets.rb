require 'osctld/commands/base'

module OsCtld
  class Commands::Self::Assets < Commands::Base
    handle :self_assets

    include Utils::Assets

    def execute
      ok(list_and_validate_assets(Daemon.get))
    end
  end
end
