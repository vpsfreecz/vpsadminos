require 'osctld/commands/base'

module OsCtld
  class Commands::Pool::AutoStartTrigger < Commands::Base
    handle :pool_autostart_trigger

    def execute
      pool = DB::Pools.find(opts[:name])
      error!('pool not found') unless pool

      manipulate(pool) do
        begin
          pool.autostart(force: true)
        rescue HookFailed => e
          error!("pre-autostart hook failed: #{e.message}")
        end

        ok
      end
    end
  end
end
