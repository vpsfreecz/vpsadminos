require 'osctld/commands/base'

module OsCtld
  class Commands::Pool::AbortExport < Commands::Base
    handle :pool_abort_export

    def execute
      pool = DB::Pools.find(opts[:name])
      error!('pool not imported') unless pool

      pool.abort_export
      ok
    end
  end
end
