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
        pool.begin_stop
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
          pool.autostop_and_wait(client_handler: client_handler, message: opts[:message])
          check_abort!(pool)

          # Verify that all containers are stopped
          loop do
            all_stopped = true

            DB::Containers.get.each do |ct|
              next if ct.pool != pool

              unless %i(staged stopped).include?(ct.state)
                msg = "Container #{ct.ident} is still #{ct.state}, waiting until stopped"
                progress(msg)
                log(:warn, msg)
                all_stopped = false
              end
            end

            check_abort!(pool)
            break if all_stopped

            check_abort!(pool)
            sleep(1)
          end
        end

        # Stop also autostop
        pool.all_stop

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

        # Remove all cgroups & BPF
        if opts[:stop_containers]
          progress('Removing cgroups')
          begin
            CGroup.rmpath_all(root_group.cgroup_path)
          rescue SystemCallError
            # If some of the cgroups are busy, just leave them be
          end

          # Clear-out BPF FS
          BpfFs.remove_pool(pool.name)
        end

        # Regenerate /etc/sub{u,g}ids and lxc-usernet
        call_cmd!(Commands::User::SubUGIds)
        call_cmd!(Commands::User::LxcUsernet)

        # Close history
        History.close(pool)

        # Remove pool from the database
        DB::Pools.remove(pool)

        # Remove outdated send/receive keys
        SendReceive.deploy
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

    def check_abort!(pool)
      error!('pool export aborted') if check_abort?(pool)
    end

    def check_abort?(pool)
      pool.abort_export? || (indirect? && Daemon.get.abort_shutdown?)
    end
  end
end
