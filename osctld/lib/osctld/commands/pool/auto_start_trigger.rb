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

      if daemon.respond_to?(:with_lifecycle_task)
        daemon.with_lifecycle_task(
          kind: :pool_autostart_trigger,
          details: { pool: pool.name }
        ) do
          trigger.call
        end
      else
        daemon.admit_lifecycle! if daemon.respond_to?(:admit_lifecycle!)
        trigger.call
      end
    end

    protected

    def daemon_hook_timeout(daemon)
      return unless daemon.respond_to?(:config)

      restart = daemon.config&.restart
      restart.respond_to?(:hook_timeout) ? restart.hook_timeout : nil
    end
  end
end
