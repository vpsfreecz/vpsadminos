require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::PrLimitUnset < Commands::Logged
    handle :ct_prlimit_unset

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.prlimits.unset(opts[:name])
      ok
    end
  end
end
