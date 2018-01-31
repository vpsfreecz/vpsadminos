module OsCtld
  class Commands::Migration::AuthKeyAdd < Commands::Logged
    handle :migration_authkey_add

    def find
      if opts[:pool]
        pool = DB::Pools.find(opts[:pool])

      else
        pool = DB::Pools.get_or_default(nil)
      end

      pool || error!('pool not found')
    end

    def execute(pool)
      pool.migration_key_chain.authorize_key(opts[:public_key])
      Migration.deploy
      ok
    end
  end
end
