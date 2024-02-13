require 'osctld/commands/base'
require 'osup'

module OsCtld
  class Commands::Pool::Import < Commands::Base
    handle :pool_import

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      if opts[:all]
        import_all
      else
        import_one(opts[:name])
      end
    end

    protected

    def import_all
      props = [
        'name',
        'mounted',
        Pool::PROPERTY_ACTIVE,
        Pool::PROPERTY_DATASET
      ]

      zfs(
        :list,
        "-H -d0 -o #{props.join(',')}",
        ''
      ).output.split("\n").each do |line|
        name, mounted, active, dataset = line.split
        next if active != 'yes' \
                || mounted != 'yes' \
                || !pool_ready?(name) \
                || DB::Pools.contains?(name)

        begin
          do_import(name, dataset)
        rescue PoolExists
          next
        rescue HookFailed => e
          log(:warn, "Pool pre-import hook failed: #{e.message}")
          next
        rescue PoolUpgradeError => e
          log(:warn, "Pool upgrade failed: #{e.message}")
          next
        end
      end

      ok
    end

    def import_one(name)
      error!('pool already imported') if DB::Pools.contains?(name)

      mounted, dataset = zfs(
        :get,
        "-H -o value mounted,#{Pool::PROPERTY_DATASET}",
        name
      ).output.strip.split

      error!('the pool is not mounted') if mounted != 'yes'

      begin
        do_import(name, dataset)
        ok
      rescue PoolExists, PoolUpgradeError, HookFailed => e
        error(e.message)
      end
    end

    def pool_ready?(name)
      sv = "pool-#{name}"

      return true unless Dir.exist?(File.join('/service', sv))

      File.exist?(File.join('/run/service', sv, 'done'))
    end

    def do_import(name, dataset)
      t1 = Time.now
      pool = Pool.new(name, dataset == '-' ? nil : dataset)

      log(:info, pool, 'Importing pool')
      Hook.run(pool, :pre_import)

      manipulate(pool) do
        DB::Pools.sync do
          if DB::Pools.contains?(name)
            raise PoolExists, "pool #{name} is already imported"
          end

          DB::Pools.add(pool)
        end

        begin
          upgrade(name)
        rescue PoolUpgradeError
          DB::Pools.remove(pool)
          raise
        end

        pool.init
        pool.setup

        if Daemon.get.shutdown?
          log(:info, 'Shutdown in progress, disabling pool')
          pool.disable
        elsif opts[:autostart]
          begin
            pool.autostart
          rescue HookFailed => e
            log(:warn, "pre-autostart hook failed: #{e.message}")
          end
        end
      end

      Hook.run(pool, :post_import)

      log(:info, pool, "Pool imported in #{(Time.now - t1).round(2)} seconds")
    end

    def upgrade(name)
      OsUp.upgrade(name)
    rescue OsUp::PoolUpToDate
      # pass
    rescue StandardError => e
      raise PoolUpgradeError.new(name, e)
    end
  end
end
