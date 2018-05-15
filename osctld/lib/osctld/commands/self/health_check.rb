require 'osctld/commands/base'

module OsCtld
  class Commands::Self::HealthCheck < Commands::Base
    handle :self_healthcheck

    def execute
      ret = []
      errors = []

      Daemon.get.assets.each do |asset|
        next if asset.valid?

        errors << {
          type: asset.type,
          path: asset.path,
          opts: asset.opts,
          errors: asset.errors,
        }
      end

      unless errors.empty?
        ret << {
          pool: nil,
          type: 'osctld',
          id: nil,
          assets: errors,
        }
      end

      pools.each do |pool|
        filter = ->(v) { v.pool == pool }

        [DB::Pools, DB::Repositories, DB::Users, DB::Groups, DB::Containers].each do |klass|
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

      elsif opts[:all]
        DB::Pools.get

      else
        []
      end
    end
  end
end
