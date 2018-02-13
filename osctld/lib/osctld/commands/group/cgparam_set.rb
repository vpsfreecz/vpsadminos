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
      set(grp, opts, apply: any_container_running?(grp))
    end

    protected
    # TODO: duplicated method, already in `Commands::Group::CGParamApply`
    def any_container_running?(grp)
      ct = grp.containers.detect { |ct| ct.state == :running }
      ct ? true : false
    end
  end
end
