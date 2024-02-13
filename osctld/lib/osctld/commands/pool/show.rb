require 'osctld/commands/base'

module OsCtld
  class Commands::Pool::Show < Commands::Base
    handle :pool_show

    def execute
      pool = DB::Pools.find(opts[:name])
      error!('pool not found') unless pool

      ok({
        name: pool.name,
        dataset: pool.dataset,
        state: pool.state,
        users: DB::Users.get.count { |v| v.pool == pool },
        groups: DB::Groups.get.count { |v| v.pool == pool },
        containers: DB::Containers.get.count { |v| v.pool == pool },
        parallel_start: pool.parallel_start,
        parallel_stop: pool.parallel_stop
      }.merge!(pool.attrs.export))
    end
  end
end
