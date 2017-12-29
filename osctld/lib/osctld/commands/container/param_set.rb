module OsCtld
  class Commands::Container::ParamSet < Commands::Base
    handle :ct_param_set
    include Utils::Log
    include Utils::CGroupParams

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      set(ct, opts, apply: ct.running?)
    end
  end
end
