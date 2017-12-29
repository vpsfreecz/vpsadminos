module OsCtld
  class Commands::Group::ParamSet < Commands::Base
    handle :group_param_set
    include Utils::Log
    include Utils::CGroupParams

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      set(grp, opts, apply: any_container_running?(grp))
    end

    protected
    # TODO: duplicated method, already in `Commands::Group::ParamApply`
    def any_container_running?(grp)
      ct = grp.containers.detect { |ct| ct.state == :running }
      ct ? true : false
    end
  end
end
