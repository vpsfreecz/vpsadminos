require 'osctld/commands/base'

module OsCtld
  class Commands::Group::CGParamList < Commands::Base
    handle :group_cgparam_list
    include Utils::CGroupParams

    def execute
      grp = DB::Groups.find(opts[:name], opts[:pool])
      return error('group not found') unless grp

      list(grp)
    end
  end
end
