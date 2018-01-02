module OsCtld
  class Commands::Container::CGParamSet < Commands::Base
    handle :ct_cgparam_set
    include Utils::Log
    include Utils::CGroupParams

    def execute
      ct = DB::Containers.find(opts[:id])
      return error('container not found') unless ct

      set(ct, opts, apply: ct.running?)
    end
  end
end
