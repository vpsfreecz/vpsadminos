module OsCtld
  class Commands::Pool::Import < Commands::Base
    handle :pool_import

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      DB::Pools.sync do
        if opts[:all]
          zfs(
            :list,
            "-H -d0 -o name,#{Pool::PROPERTY}",
            ''
          )[:output].split("\n").each do |line|
            name, active = line.split
            next if active != 'yes' || DB::Pools.contains?(name)

            pool = Pool.new(name)
            pool.setup
            DB::Pools.add(pool)
          end
          ok

        else
          next error('pool already imported') if DB::Pools.contains?(opts[:name])

          pool = Pool.new(opts[:name])
          pool.setup
          DB::Pools.add(pool)
          ok
        end
      end
    end
  end
end
