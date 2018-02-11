module OsCtld
  class Commands::Pool::AutoStartCancel < Commands::Base
    handle :pool_autostart_cancel

    def execute
      pool = DB::Pools.find(opts[:name])
      error!('pool not found') unless pool

      pool.inclusively do
        if pool.autostart_plan.running?
          pool.autostart_plan.stop
          ok

        else
          error('auto-starting plan is not running')
        end
      end
    end
  end
end
