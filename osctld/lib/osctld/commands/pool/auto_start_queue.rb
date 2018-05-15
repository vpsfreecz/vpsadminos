require 'osctld/commands/base'

module OsCtld
  class Commands::Pool::AutoStartQueue < Commands::Base
    handle :pool_autostart_queue

    def execute
      pool = DB::Pools.find(opts[:name])
      error!('pool not found') unless pool

      pool.inclusively do
        ok(pool.autostart_plan.get_queue.map(&:to_h))
      end
    end
  end
end
