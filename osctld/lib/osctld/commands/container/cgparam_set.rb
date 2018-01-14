module OsCtld
  class Commands::Container::CGParamSet < Commands::Logged
    handle :ct_cgparam_set
    include Utils::Log
    include Utils::CGroupParams

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      set(ct, opts, apply: ct.running?)
    end
  end
end
