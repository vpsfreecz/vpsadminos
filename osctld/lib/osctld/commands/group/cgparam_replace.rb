require 'osctld/commands/base'

module OsCtld
  class Commands::Group::CGParamReplace < Commands::Base
    handle :group_cgparam_replace

    include OsCtl::Lib::Utils::Log
    include Utils::CGroupParams

    def execute
      grp = DB::Groups.find(opts[:name], opts[:pool])
      return error('group not found') unless grp

      replace(grp)
    end
  end
end
