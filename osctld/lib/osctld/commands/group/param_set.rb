module OsCtld
  class Commands::Group::ParamSet < Commands::Base
    handle :group_param_set

    def execute
      grp = GroupList.find(opts[:name])
      return error('group not found') unless grp

      params = grp.import_params([{
        subsystem: opts[:subsystem],
        parameter: opts[:parameter],
        value: opts[:value],
      }])

      grp.set(params)

      ret = call_cmd(Commands::Group::ParamApply, name: grp.name)
      return ret unless ret[:status]

      ok

    rescue CGroupSubsystemNotFound, CGroupParameterNotFound => e
      error(e.message)
    end
  end
end
