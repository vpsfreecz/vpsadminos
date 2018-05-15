require 'osctld/commands/base'

module OsCtld
  class Commands::Pool::AutoStartTrigger < Commands::Base
    handle :pool_autostart_trigger

    def execute
      pool = DB::Pools.find(opts[:name])
      error!('pool not found') unless pool

      pool.inclusively do
        if pool.autostart_plan.running?
          error('auto-starting plan is already running')

        else
          pool.autostart_plan.generate
          pool.autostart_plan.start
          ok
        end
      end
    end
  end
end
