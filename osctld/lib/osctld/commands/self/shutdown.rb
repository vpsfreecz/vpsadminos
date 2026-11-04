require 'osctld/commands/base'

module OsCtld
  class Commands::Self::Shutdown < Commands::Base
    handle :self_shutdown

    def execute
      Daemon.get.run_shutdown { execute_shutdown }
    end

    protected

    def execute_shutdown
      grabbed_pools = []
      grabbed_cts = []
      wall_msg =
        if opts[:wall]
          opts[:message] || 'System is shutting down'
        end

      # Grab manipulation locks of all pools
      grab_pools(grabbed_pools)

      check_abort!

      # Disable all pools
      DB::Pools.get.each do |pool|
        progress("Disabling pool #{pool.name}")
        pool.exclusively { pool.disable }
      end
      check_abort!

      # Grab manipulation locks of all containers
      grab_all_cts(grabbed_cts)

      check_abort!

      # Stop containers from all pools
      stop_pools = DB::Pools.get

      if stop_pools.length > 1
        progress('Stopping all containers')
        progress_tracker = ProgressTracker.new

        stop_pools.each do |pool|
          break if check_abort?

          pool.begin_stop
          pool.autostop_no_wait(message: wall_msg, client_handler:, progress_tracker:)
        end

        stop_pools.each do |pool|
          break if check_abort?

          pool.wait_for_autostop
        end

        check_abort!
      end

      # Export pools one by one
      DB::Pools.get.each do |pool|
        check_abort!

        progress("Exporting pool #{pool.name}")

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

      ok
    ensure
      original_error = $!
      cleanup_error = nil

      # The operation, not the lifetime of its setup/client thread, owns these
      # holds. Nested export may already have released some container locks.
      Thread.handle_interrupt(Exception => :never) do
        [grabbed_cts, grabbed_pools].each do |grabbed|
          release_grabbed(grabbed)
        rescue Exception => e # rubocop:disable Lint/RescueException -- Preserve interruption and cleanup outcomes.
          cleanup_error ||= e
        end
      end
      raise cleanup_error if cleanup_error && original_error.nil?
    end

    def grab_pools(grabbed)
      progress('Grabbing pools')
      pools = DB::Pools.get

      loop do
        break if check_abort?

        pools.delete_if do |pool|
          break if check_abort?

          begin
            Thread.handle_interrupt(Exception => :never) do
              pool.acquire_manipulation_lock(self)
              grabbed << pool
            end
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

    def grab_all_cts(grabbed)
      progress('Grabbing all containers')
      cts = DB::Containers.get

      loop do
        break if check_abort?

        cts.delete_if do |ct|
          break if check_abort?

          begin
            Thread.handle_interrupt(Exception => :never) do
              ct.acquire_manipulation_lock(self)
              grabbed << ct
            end
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
      error = nil
      grabbed.reverse_each do |v|
        v.release_manipulation_lock if v.manipulated_by.equal?(self)
      rescue Exception => e # rubocop:disable Lint/RescueException -- Preserve interruption and cleanup outcomes.
        error ||= e
      end
      raise error if error
    end

    def check_abort!
      error!('shutdown aborted') if Daemon.get.abort_shutdown?
    end

    def check_abort?
      Daemon.get.abort_shutdown?
    end
  end
end
