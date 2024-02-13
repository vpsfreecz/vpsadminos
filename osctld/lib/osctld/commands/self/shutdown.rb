require 'osctld/commands/base'

module OsCtld
  class Commands::Self::Shutdown < Commands::Base
    handle :self_shutdown

    def execute
      # Make sure that osctld crash/restart will not stop the shutdown
      Daemon.get.begin_shutdown

      # Grab manipulation locks of all pools
      grabbed_pools = grab_pools

      if check_abort?
        release_grabbed(grabbed_pools)
        error!('shutdown aborted')
      end

      # Disable all pools
      DB::Pools.get.each do |pool|
        progress("Disabling pool #{pool.name}")
        pool.exclusively { pool.disable }
      end
      check_abort!

      # Grab manipulation locks of all containers
      grabbed_cts = grab_all_cts

      if check_abort?
        release_grabbed(grabbed_cts)
        release_grabbed(grabbed_pools)
        error!('shutdown aborted')
      end

      # Export pools one by one
      DB::Pools.get.each do |pool|
        if check_abort?
          release_grabbed(grabbed_cts)
          release_grabbed(grabbed_pools)
          error!('shutdown aborted')
        end

        progress("Exporting pool #{pool.name}")

        wall_msg =
          if opts[:wall]
            opts[:message] || 'System is shutting down'
          end

        call_cmd!(
          Commands::Pool::Export,
          name: pool.name,
          force: true,
          grab_containers: false,
          stop_containers: true,
          unregister_users: false,
          message: wall_msg
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
      grabbed = []

      loop do
        break if check_abort?

        pools.delete_if do |pool|
          break if check_abort?

          begin
            pool.acquire_manipulation_lock(self)
            grabbed << pool
            true
          rescue ResourceLocked => e
            progress(e.message)
            false
          end
        end

        break if pools.empty?

        sleep(1)
      end

      grabbed
    end

    def grab_all_cts
      progress('Grabbing all containers')
      cts = DB::Containers.get
      grabbed = []

      loop do
        break if check_abort?

        cts.delete_if do |ct|
          break if check_abort?

          begin
            ct.acquire_manipulation_lock(self)
            grabbed << ct
            true
          rescue ResourceLocked => e
            progress(e.message)
            false
          end
        end

        break if cts.empty?

        sleep(1)
      end

      grabbed
    end

    def release_grabbed(grabbed)
      grabbed.each do |v|
        # The locks may have already been released by Commands::Pool::Export
        v.release_manipulation_lock if v.manipulated_by == self
      end
    end

    def check_abort!
      error!('shutdown aborted') if Daemon.get.abort_shutdown?
    end

    def check_abort?
      Daemon.get.abort_shutdown?
    end
  end
end
