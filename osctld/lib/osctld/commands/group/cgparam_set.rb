module OsCtld
  class Commands::Group::CGParamSet < Commands::Logged
    handle :group_cgparam_set
    include OsCtl::Lib::Utils::Log
    include Utils::CGroupParams

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      set(grp, opts, apply: grp.any_container_running?)
    end
  end
end
