module OsCtld
  class Commands::Group::CGParamUnset < Commands::Base
    handle :group_cgparam_unset
    include Utils::CGroupParams

    def execute
      grp = DB::Groups.find(opts[:name])
      return error('group not found') unless grp

      unset(grp, opts)
    end
  end
end
