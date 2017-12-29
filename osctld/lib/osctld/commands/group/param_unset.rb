module OsCtld
  class Commands::Group::ParamUnset < Commands::Base
    handle :group_param_unset
    include Utils::CGroupParams

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      unset(grp, opts)
    end
  end
end
