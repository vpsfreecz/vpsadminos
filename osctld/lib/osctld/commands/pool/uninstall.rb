module OsCtld
  class Commands::Pool::Uninstall < Commands::Base
    handle :pool_uninstall

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      name = opts[:name]
      return error('export the pool first') if DB::Pools.contains?(name)

      zfs(:set, "#{Pool::PROPERTY}=no", name)
      zfs(:inherit, Pool::PROPERTY, name)
      ok
    end
  end
end
