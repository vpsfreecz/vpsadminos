require 'osctld/commands/base'

module OsCtld
  class Commands::User::Assets < Commands::Base
    handle :user_assets

    include Utils::Assets

    def execute
      u = DB::Users.find(opts[:name], opts[:pool])
      return error('user not found') unless u

      ok(list_and_validate_assets(u))
    end
  end
end
