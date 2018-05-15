require 'osctld/commands/base'

module OsCtld
  class Commands::Group::Assets < Commands::Base
    handle :group_assets

    include Utils::Assets

    def execute
      grp = DB::Groups.find(opts[:name], opts[:pool])
      return error('group not found') unless grp

      ok(list_and_validate_assets(grp))
    end
  end
end
