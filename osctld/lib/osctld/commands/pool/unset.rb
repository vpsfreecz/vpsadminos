module OsCtld
  class Commands::Pool::Unset < Commands::Logged
    handle :pool_unset

    def find
      pool = DB::Pools.find(opts[:name])
      pool || error!('pool not found')
    end

    def execute(pool)
      pool.exclusively do
        pool.unset(opts[:options].map(&:to_sym))
      end

      ok
    end
  end
end
