require 'osctld/commands/base'

module OsCtld
  class Commands::Self::HealthCheck < Commands::Base
    handle :self_healthcheck

    def execute
      validator = Assets::Validator.new

      # Collect all assets
      daemon_assets = Daemon.get.assets
      validator.add_assets(daemon_assets)

      pool_entity_assets = {}

      pools.each do |pool|
        filter = ->(v) { v.pool == pool }

        [DB::Pools, DB::Repositories, DB::Users, DB::Groups, DB::Containers].each do |klass|
          entities = klass.get.select(&filter)

          entities.each do |ent|
            ent_assets = ent.assets

            pool_entity_assets[pool.name] ||= {}
            pool_entity_assets[pool.name][ent] = ent_assets

            validator.add_assets(ent_assets)
          end
        end
      end

      # Run validation
      validator.validate

      # Collect errors and return them to the client
      ret = []
      daemon_errors = []

      daemon_assets.each do |asset|
        next if %i(valid unknown).include?(asset.state)

        daemon_errors << {
          type: asset.type,
          path: asset.path,
          opts: asset.opts,
          errors: asset.errors,
        }
      end

      unless daemon_errors.empty?
        ret << {
          pool: nil,
          type: 'osctld',
          id: nil,
          assets: daemon_errors,
        }
      end

      pool_entity_assets.each do |pool, entities|
        entities.each do |ent, ent_assets|
          ent_errors = []

          ent_assets.each do |asset|
            next if %i(valid unknown).include?(asset.state)

            ent_errors << {
              type: asset.type,
              path: asset.path,
              opts: asset.opts,
              errors: asset.errors,
            }
          end

          next if ent_errors.empty?

          ret << {
            pool: ent.pool.name,
            type: ent.class.name.split('::').last.downcase,
            id: ent.id,
            assets: ent_errors,
          }
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
