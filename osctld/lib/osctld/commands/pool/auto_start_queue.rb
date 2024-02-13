require 'osctld/commands/base'

module OsCtld
  class Commands::Pool::AutoStartQueue < Commands::Base
    handle :pool_autostart_queue

    def execute
      pool = DB::Pools.find(opts[:name])
      error!('pool not found') unless pool

      pool.inclusively do
        if pool.imported?
          ok(pool.autostart_plan.queue.map do |cmd|
            {
              id: cmd.id,
              priority: cmd.priority
            }
          end)
        else
          ok([])
        end
      end
    end
  end
end
