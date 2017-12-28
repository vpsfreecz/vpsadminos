module OsCtld
  class Commands::Group::ParamUnset < Commands::Base
    handle :group_param_unset

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      grp.unset([{
        subsystem: opts[:subsystem],
        parameter: opts[:parameter],
      }])

      ok
    end
  end
end
