module OsCtld
  class Commands::Pool::Export < Commands::Base
    handle :pool_export

    def execute
      pool = DB::Pools.find(opts[:name])
      error!('pool not imported') unless pool

      # Stop autostart plan, if active
      pool.stop

      # Disable the pool
      pool.exclusively { pool.disable }

      # Stop all containers
      if opts[:stop_containers]
        progress('Stopping all containers')
        cts = DB::Containers.get.select { |ct| ct.pool == pool }

        cts.each_with_index do |ct, i|
          progress("[#{i+1}/#{cts.count}] Stopping container #{ct.ident}")
          call_cmd!(
            Commands::Container::Stop,
            pool: pool.name,
            id: ct.id,
            progress: false
          )
        end
      end

      # Unregister all entities
      progress('Unregistering users, groups and containers')

      # Preserve root group
      root_group = DB::Groups.root(pool)

      [DB::Containers, DB::Users, DB::Groups].each do |klass|
        klass.get.each do |obj|
          next if obj.pool != pool

          if obj.is_a?(User)
            obj.exclusively { UserControl::Supervisor.stop_server(obj) }

            call_cmd!(
              Commands::User::Unregister,
              pool: pool.name,
              name: obj.name
            ) if opts[:unregister_users]

          elsif obj.is_a?(Container)
            Monitor::Master.demonitor(obj)
            obj.exclusively { Console.remove(obj) }
          end

          klass.remove(obj)
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

      ok
    end
  end
end
