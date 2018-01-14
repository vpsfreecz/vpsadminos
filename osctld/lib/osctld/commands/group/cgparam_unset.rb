module OsCtld
  class Commands::Group::CGParamUnset < Commands::Logged
    handle :group_cgparam_unset
    include Utils::CGroupParams

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      unset(grp, opts)
    end
  end
end
