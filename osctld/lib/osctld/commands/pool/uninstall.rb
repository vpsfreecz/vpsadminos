module OsCtld
  class Commands::Pool::Uninstall < Commands::Base
    handle :pool_uninstall

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

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
