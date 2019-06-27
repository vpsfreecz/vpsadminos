require 'osctld/commands/base'

module OsCtld
  class Commands::Pool::AutoStartCancel < Commands::Base
    handle :pool_autostart_cancel

    def execute
      pool = DB::Pools.find(opts[:name])
      error!('pool not found') unless pool

      manipulate(pool) do
        pool.autostart_plan.clear
        ok
      end
    end
  end
end
