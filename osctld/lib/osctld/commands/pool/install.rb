module OsCtld
  class Commands::Pool::Install < Commands::Base
    handle :pool_install

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      pool = Pool.new(opts[:name])
      return error('pool already exists') if DB::Pools.contains?(pool.name)

      pool.exclusively do
        zfs(:set, "#{Pool::PROPERTY}=yes", pool.name)
        pool.setup

        DB::Pools.add(pool)
      end

      ok
    end
  end
end
