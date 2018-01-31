module OsCtld
  class Commands::Migration::AuthKeyList < Commands::Base
    handle :migration_authkey_list

    def execute
      if opts[:pool]
        pool = DB::Pools.find(opts[:pool])

      else
        pool = DB::Pools.get_or_default(nil)
      end

      error!('pool not found') unless pool

      ok(pool.migration_key_chain.authorized_keys)
    end
  end
end
