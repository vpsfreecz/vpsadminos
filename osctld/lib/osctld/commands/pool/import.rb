require 'osctld/commands/base'
require 'osup'

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

            begin
              import(name, dataset)

            rescue PoolUpgradeError => e
              log(:warn, "Pool upgrade failed: #{e.message}")
              next
            end
          end

          ok

        else
          next error('pool already imported') if DB::Pools.contains?(opts[:name])

          dataset = zfs(
            :get,
            "-H -o value #{Pool::PROPERTY_DATASET}",
            opts[:name]
          )[:output].strip

          begin
            import(opts[:name], dataset)
            ok

          rescue PoolUpgradeError => e
            next error(e.message)
          end
        end
      end
    end

    protected
    def import(name, dataset)
      upgrade(name)
      pool = Pool.new(name, dataset == '-' ? nil : dataset)
      pool.setup
      DB::Pools.add(pool)
      pool.autostart if opts[:autostart]
    end

    def upgrade(name)
      OsUp.upgrade(name)

    rescue OsUp::PoolUpToDate
      # pass

    rescue => e
      raise PoolUpgradeError.new(name, e)
    end
  end
end
