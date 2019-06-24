require 'osctld/commands/logged'

module OsCtld
  class Commands::Receive::AuthKeyAdd < Commands::Logged
    handle :receive_authkey_add

    def find
      if opts[:pool]
        pool = DB::Pools.find(opts[:pool])

      else
        pool = DB::Pools.get_or_default(nil)
      end

      pool || error!('pool not found')
    end

    def execute(pool)
      pool.send_receive_key_chain.authorize_key(opts[:public_key])
      SendReceive.deploy
      ok
    end
  end
end
