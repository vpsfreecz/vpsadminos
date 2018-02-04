module OsCtld
  class Commands::Pool::Assets < Commands::Base
    handle :pool_assets

    include Utils::Assets

    def execute
      pool = DB::Pools.find(opts[:name])
      return error('pool not found') unless pool

      ok(list_and_validate_assets(pool))
    end
  end
end
