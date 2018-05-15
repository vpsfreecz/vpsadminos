require 'osctld/commands/base'

module OsCtld
  class Commands::Migration::KeyPath < Commands::Base
    handle :migration_key_path

    def execute
      if opts[:pool]
        pool = DB::Pools.find(opts[:pool])

      else
        pool = DB::Pools.get_or_default(nil)
      end

      error!('pool not found') unless pool

      ok(
        private_key: pool.migration_key_chain.private_key_path,
        public_key: pool.migration_key_chain.public_key_path,
      )
    end
  end
end
