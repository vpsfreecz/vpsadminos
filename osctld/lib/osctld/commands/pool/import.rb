module OsCtld
  class Commands::Pool::Import < Commands::Base
    handle :pool_import

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      DB::Pools.sync do
        if opts[:all]
          zfs(
            :list,
            "-H -d0 -o name,#{Pool::PROPERTY_ACTIVE},#{Pool::PROPERTY_DATASET}",
            ''
          )[:output].split("\n").each do |line|
            name, active, dataset = line.split
            next if active != 'yes' || DB::Pools.contains?(name)

            pool = Pool.new(name, dataset == '-' ? nil : dataset)
            pool.setup
            DB::Pools.add(pool)
            pool.autostart if opts[:autostart]
          end
          ok

        else
          next error('pool already imported') if DB::Pools.contains?(opts[:name])

          dataset = zfs(
            :get,
            "-H -o value #{Pool::PROPERTY_DATASET}",
            opts[:name]
          )[:output].strip

          pool = Pool.new(opts[:name], dataset == '-' ? nil : dataset)
          pool.setup
          DB::Pools.add(pool)
          pool.autostart if opts[:autostart]
          ok
        end
      end
    end
  end
end
