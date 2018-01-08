module OsCtld
  class Commands::Pool::Uninstall < Commands::Base
    handle :pool_uninstall

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      name = opts[:name]
      return error('export the pool first') if DB::Pools.contains?(name)

      zfs(:set, "#{Pool::PROPERTY_ACTIVE}=no", name)
      zfs(:inherit, Pool::PROPERTY_ACTIVE, name)
      zfs(:inherit, Pool::PROPERTY_DATASET, name)
      ok
    end
  end
end
