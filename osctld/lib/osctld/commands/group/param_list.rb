module OsCtld
  class Commands::Group::ParamList < Commands::Base
    handle :group_param_list
    include Utils::CGroupParams

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      list(grp)
    end
  end
end
