require 'osctld/commands/base'

module OsCtld
  class Commands::Self::Shutdown < Commands::Base
    handle :self_shutdown

    def execute
      # Disable all pools
      DB::Pools.get.each do |pool|
        pool.exclusively { pool.disable }
      end

      # Export pools one by one
      DB::Pools.get.each do |pool|
        progress("Disabling pool #{pool.name}")

        call_cmd!(
          Commands::Pool::Export,
          name: pool.name,
          force: true,
          stop_containers: true,
          unregister_users: false
        )
      end

      ok
    end
  end
end
