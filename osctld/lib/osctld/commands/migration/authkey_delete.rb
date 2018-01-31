module OsCtld
  class Commands::Migration::AuthKeyDelete < Commands::Logged
    handle :migration_authkey_delete

    def find
      if opts[:pool]
        pool = DB::Pools.find(opts[:pool])

      else
        pool = DB::Pools.get_or_default(nil)
      end

      pool || error!('pool not found')
    end

    def execute(pool)
      pool.migration_key_chain.revoke_key(opts[:index])
      Migration.deploy
      ok
    end
  end
end
