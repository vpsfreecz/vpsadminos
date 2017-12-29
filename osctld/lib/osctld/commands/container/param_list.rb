module OsCtld
  class Commands::Container::ParamList < Commands::Base
    handle :ct_param_list
    include Utils::CGroupParams

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      list(ct)
    end
  end
end
