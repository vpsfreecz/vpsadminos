require 'osctld/commands/base'

module OsCtld
  class Commands::Receive::AuthKeyList < Commands::Base
    handle :receive_authkey_list

    def execute
      pool = if opts[:pool]
               DB::Pools.find(opts[:pool])

             else
               DB::Pools.get_or_default(nil)
             end

      error!('pool not found') unless pool

      ok(pool.send_receive_key_chain.export)
    end
  end
end
