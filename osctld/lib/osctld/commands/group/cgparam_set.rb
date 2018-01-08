module OsCtld
  class Commands::Group::CGParamSet < Commands::Base
    handle :group_cgparam_set
    include Utils::Log
    include Utils::CGroupParams

    def execute
      grp = DB::Groups.find(opts[:name], opts[:pool])
      return error('group not found') unless grp

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
