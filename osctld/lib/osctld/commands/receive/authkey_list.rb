require 'osctld/commands/base'

module OsCtld
  class Commands::Receive::AuthKeyList < Commands::Base
    handle :receive_authkey_list

    def execute
      if opts[:pool]
        pool = DB::Pools.find(opts[:pool])

      else
        pool = DB::Pools.get_or_default(nil)
      end

      error!('pool not found') unless pool

      ok(pool.send_receive_key_chain.export)
    end
  end
end
