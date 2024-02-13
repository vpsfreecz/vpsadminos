require 'osctld/commands/base'

module OsCtld
  class Commands::Pool::List < Commands::Base
    handle :pool_list

    def execute
      ret = []

      DB::Pools.get.each do |pool|
        next if opts[:names] && !opts[:names].include?(pool.name)

        ret << {
          name: pool.name,
          dataset: pool.dataset,
          state: pool.state,
          users: DB::Users.get.count { |v| v.pool == pool },
          groups: DB::Groups.get.count { |v| v.pool == pool },
          containers: DB::Containers.get.count { |v| v.pool == pool },
          parallel_start: pool.parallel_start,
          parallel_stop: pool.parallel_stop
        }.merge!(pool.attrs.export)
      end

      ok(ret)
    end
  end
end
