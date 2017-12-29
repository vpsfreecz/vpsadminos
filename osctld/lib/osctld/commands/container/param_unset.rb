module OsCtld
  class Commands::Container::ParamUnset < Commands::Base
    handle :ct_param_unset
    include Utils::CGroupParams

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      unset(ct, opts)
    end
  end
end
