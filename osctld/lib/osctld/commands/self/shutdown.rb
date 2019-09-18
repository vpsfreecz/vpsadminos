require 'osctld/commands/base'

module OsCtld
  class Commands::Self::Shutdown < Commands::Base
    handle :self_shutdown

    def execute
      # Make sure that osctld crash/restart will not stop the shutdown
      Daemon.get.begin_shutdown

      # Grab manipulation locks of all pools
      grab_pools

      # Disable all pools
      DB::Pools.get.each do |pool|
        progress("Disabling pool #{pool.name}")
        pool.exclusively { pool.disable }
      end

      # Grab manipulation locks of all containers
      grab_all_cts

      # Export pools one by one
      DB::Pools.get.each do |pool|
        progress("Exporting pool #{pool.name}")

        call_cmd!(
          Commands::Pool::Export,
          name: pool.name,
          force: true,
          grab_containers: false,
          stop_containers: true,
          unregister_users: false,
        )
      end

      # Confirm the shutdown for anyone waiting for it, i.e. osctl shutdown
      Daemon.get.confirm_shutdown

      ok
    end

    protected
    def grab_pools
      progress('Grabbing pools')
      pools = DB::Pools.get

      loop do
        pools.delete_if do |pool|
          begin
            pool.acquire_manipulation_lock(self)
            true

          rescue ResourceLocked => e
            progress(e.message)
            false
          end
        end

        break if pools.empty?
        sleep(1)
      end
    end

    def grab_all_cts
      progress('Grabbing all containers')
      cts = DB::Containers.get

      loop do
        cts.delete_if do |ct|
          begin
            ct.acquire_manipulation_lock(self)
            true

          rescue ResourceLocked => e
            progress(e.message)
            false
          end
        end

        break if cts.empty?
        sleep(1)
      end
    end
  end
end
