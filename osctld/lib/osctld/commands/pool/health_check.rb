module OsCtld
  class Commands::Pool::HealthCheck < Commands::Base
    handle :pool_healthcheck

    def execute
      ret = []

      pools.each do |pool|
        filter = ->(v) { v.pool == pool }

        [DB::Pools, DB::Users, DB::Groups, DB::Containers].each do |klass|
          entities = klass.get.select(&filter)

          entities.each do |ent|
            errors = []

            ent.assets.each do |asset|
              next if asset.valid?

              errors << {
                type: asset.type,
                path: asset.path,
                opts: asset.opts,
                errors: asset.errors,
              }
            end

            next if errors.empty?

            ret << {
              pool: ent.pool.name,
              type: ent.class.name.split('::').last.downcase,
              id: ent.id,
              assets: errors,
            }
          end
        end
      end

      ok(ret)
    end

    protected
    def pools
      if opts[:pools]
        opts[:pools].map do |name|
          DB::Pools.find(name) || (raise CommandFailed, "pool #{name} not found")
        end

      else
        DB::Pools.get
      end
    end
  end
end
