module OsCtld
  class Commands::Container::ParamApply < Commands::Base
    handle :ct_param_apply

    include Utils::Log
    include Utils::CGroupParams

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      log(:info, "CT #{ct.id}", "Configuring cgroups")

      ret = call_cmd(Commands::Group::ParamApply, name: ct.group.name)
      return ret unless ret[:status]

      apply(ct, force: ct.running?)

      ok
    end
  end
end
