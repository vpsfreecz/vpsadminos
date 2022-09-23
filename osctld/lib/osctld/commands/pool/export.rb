require 'osctld/commands/base'
require 'thread'

module OsCtld
  class Commands::Pool::Export < Commands::Base
    handle :pool_export

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      pool = DB::Pools.find(opts[:name])

      unless pool
        if opts[:if_imported]
          progress('pool not imported')
          return ok
        else
          error!('pool not imported')
        end
      end

      # Check for running containers
      if !opts[:force] && DB::Containers.get.detect { |ct| ct.pool == pool && ct.running? }
        error!('the pool has running containers')
      end

      begin
        Hook.run(pool, :pre_export)
      rescue HookFailed => e
        error!("pre-export hook failed: #{e.message}")
      end

      manipulate(pool) do
        pool.begin_export

        # Do not autostart any more containers
        pool.stop
        check_abort!(pool)

        # Disable the pool
        pool.exclusively { pool.disable }
        check_abort!(pool)

        # Grab manipulation locks of all containers
        grab_cts(pool) unless opts[:grab_containers] === false
        check_abort!(pool)

        # Stop all containers
        if opts[:stop_containers]
          progress('Stopping all containers')
          stop_cts(pool)
          check_abort!(pool)
        end

        # Unregister all entities
        progress('Unregistering users, groups and containers')

        # Preserve root group
        root_group = DB::Groups.root(pool)

        [
          DB::Containers,
          DB::Users,
          DB::Groups,
          DB::Repositories,
          DB::IdRanges,
        ].each do |klass|
          klass.get.each do |obj|
            next if obj.pool != pool

            if obj.is_a?(User)
              obj.exclusively { UserControl::Supervisor.stop_server(obj) }

              if opts[:unregister_users] && opts[:stop_containers]
                call_cmd!(
                  Commands::User::Unregister,
                  pool: pool.name,
                  name: obj.name
                )

                # When a user with the same name is going to be imported again,
                # he may have a different ugid than before. All files in his
                # directory would then have an incorrect owner.
                syscmd("rm -rf \"#{obj.userdir}\"")
              end

            elsif obj.is_a?(Container)
              obj.unregister
              Monitor::Master.demonitor(obj)
              Console.remove(obj)
            end

            klass.remove(obj)
            obj.release_manipulation_lock if obj.is_a?(Container)
          end
        end

        # Remove all cgroups
        if opts[:stop_containers]
          progress('Removing cgroups')
          begin
            CGroup.rmpath_all(root_group.cgroup_path)
          rescue SystemCallError
            # If some of the cgroups are busy, just leave them be
          end
        end

        # Regenerate /etc/sub{u,g}ids and lxc-usernet
        call_cmd!(Commands::User::SubUGIds)
        call_cmd!(Commands::User::LxcUsernet)

        # Close history
        History.close(pool)

        # Remove pool from the database
        DB::Pools.remove(pool)
      end

      Hook.run(pool, :post_export)
      ok
    end

    protected
    def grab_cts(pool)
      progress('Grabbing all containers')
      cts = DB::Containers.get.select { |ct| ct.pool == pool }

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

    def stop_cts(pool)
      # Sort containers by reversed autostart priority -- containers with
      # the lowest priority are stopped first
      cts = DB::Containers.get.select { |ct| ct.pool == pool }
      cts.sort! do |a, b|
        if a.autostart && b.autostart
          a.autostart <=> b.autostart

        elsif a.autostart
          -1

        elsif b.autostart
          1

        else
          0
        end
      end
      cts.reverse!

      total = cts.count
      done = 0
      mutex = Mutex.new

      plan = ExecutionPlan.new
      cts.each { |ct| plan << ct }

      check_abort!(pool)

      plan.run(pool.parallel_stop) do |ct|
        next if check_abort?(pool)

        mutex.synchronize do
          done += 1
          progress(
            "[#{done}/#{total}] "+
            (ct.ephemeral? ? 'Deleting ephemeral container' : 'Stopping container')+
            " #{ct.ident}"
          )
        end

        if ct.ephemeral?
          call_cmd!(
            Commands::Container::Delete,
            pool: pool.name,
            id: ct.id,
            force: true,
            progress: false,
            manipulation_lock: 'ignore',
          )
        else
          call_cmd!(
            Commands::Container::Stop,
            pool: pool.name,
            id: ct.id,
            destroy_lxcfs: true,
            progress: false,
            manipulation_lock: 'ignore',
          )

          pool.autostart_plan.clear_ct(ct)
        end
      end

      plan.wait
    end

    def check_abort!(pool)
      error!('pool export aborted') if check_abort?(pool)
    end

    def check_abort?(pool)
      pool.abort_export? || (indirect? && Daemon.get.abort_shutdown?)
    end
  end
end
