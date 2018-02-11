module OsCtld
  class Commands::Pool::Export < Commands::Base
    handle :pool_export

    def execute
      DB::Pools.sync do
        pool = DB::Pools.find(opts[:name])
        next error('pool not imported') unless pool

        # TODO:
        #  - don't leave any containers running?
        #  - unregister system users?

        pool.stop

        [DB::Containers, DB::Users, DB::Groups].each do |klass|
          klass.get do |objs|
            objs.delete_if do |obj|
              next if obj.pool != pool

              if obj.is_a?(User)
                obj.exclusively { UserControl::Supervisor.stop_server(obj) }

              elsif obj.is_a?(Container)
                Monitor::Master.demonitor(obj)
                obj.exclusively { Console.remove(obj) }
              end

              true
            end
          end
        end

        call_cmd(Commands::User::SubUGIds)
        call_cmd(Commands::User::LxcUsernet)

        History.close(pool)

        DB::Pools.remove(pool)
        ok
      end
    end
  end
end
