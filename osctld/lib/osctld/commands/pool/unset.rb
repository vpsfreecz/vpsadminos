require 'osctld/commands/logged'

module OsCtld
  class Commands::Pool::Unset < Commands::Logged
    handle :pool_unset

    def find
      pool = DB::Pools.find(opts[:name])
      pool || error!('pool not found')
    end

    def execute(pool)
      manipulate(pool) do
        changes = {}

        changes[:options] = opts[:options].map(&:to_sym) if opts[:options]
        changes[:attrs] = opts[:attrs] if opts[:attrs]

        pool.unset(changes)
        ok
      end
    end
  end
end
