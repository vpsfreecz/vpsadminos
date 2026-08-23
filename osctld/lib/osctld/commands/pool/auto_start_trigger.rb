require 'osctld/commands/base'

module OsCtld
  class Commands::Pool::AutoStartTrigger < Commands::Base
    handle :pool_autostart_trigger

    def execute
      daemon = Daemon.get
      pool = DB::Pools.find(opts[:name])
      error!('pool not found') unless pool

      trigger = proc do
        manipulate(pool) do
          begin
            pool.autostart(
              force: true,
              hook_timeout: daemon_hook_timeout(daemon)
            )
          rescue HookFailed => e
            error!("pre-autostart hook failed: #{e.message}")
          end

          ok
        end
      end

      daemon.with_lifecycle_task(
        kind: :pool_autostart_trigger,
        details: { pool: pool.name }
      ) do
        trigger.call
      end
    end

    protected

    def daemon_hook_timeout(daemon)
      daemon.config.restart.hook_timeout
    end
  end
end
