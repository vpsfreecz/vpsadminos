module OsCtld
  class Commands::Group::CGParamList < Commands::Base
    handle :group_cgparam_list
    include Utils::CGroupParams

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      list(grp)
    end
  end
end
