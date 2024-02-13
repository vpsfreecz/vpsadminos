require 'osctld/commands/base'

module OsCtld
  class Commands::Send::KeyPath < Commands::Base
    handle :send_key_path

    def execute
      pool = if opts[:pool]
               DB::Pools.find(opts[:pool])

             else
               DB::Pools.get_or_default(nil)
             end

      error!('pool not found') unless pool

      ok(
        private_key: pool.send_receive_key_chain.private_key_path,
        public_key: pool.send_receive_key_chain.public_key_path
      )
    end
  end
end
