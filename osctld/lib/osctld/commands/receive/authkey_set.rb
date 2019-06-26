require 'osctld/commands/logged'

module OsCtld
  class Commands::Receive::AuthKeySet < Commands::Logged
    handle :receive_authkey_set

    def find
      if opts[:pool]
        pool = DB::Pools.find(opts[:pool])

      else
        pool = DB::Pools.get_or_default(nil)
      end

      pool || error!('pool not found')
    end

    def execute(pool)
      pool.send_receive_key_chain.replace_authorized_keys(opts[:public_keys])
      SendReceive.deploy
      ok
    end
  end
end
