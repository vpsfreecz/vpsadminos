require 'osctld/commands/logged'

module OsCtld
  class Commands::Receive::AuthKeyDelete < Commands::Logged
    handle :receive_authkey_delete

    def find
      if opts[:pool]
        pool = DB::Pools.find(opts[:pool])

      else
        pool = DB::Pools.get_or_default(nil)
      end

      pool || error!('pool not found')
    end

    def execute(pool)
      pool.send_receive_key_chain.revoke_key(opts[:index])
      SendReceive.deploy
      ok
    end
  end
end
