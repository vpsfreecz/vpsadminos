module OsCtld
  class Commands::Container::PrLimitUnset < Commands::Base
    handle :ct_prlimit_unset

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.exclusively do
        ct.prlimit_unset(opts[:name])
        ok
      end
    end
  end
end
