require 'osctld/commands/logged'

module OsCtld
  class Commands::Pool::Set < Commands::Logged
    handle :pool_set

    def find
      pool = DB::Pools.find(opts[:name])
      pool || error!('pool not found')
    end

    def execute(pool)
      changes = {}

      opts.each do |k, v|
        case k
        when :parallel_start, :parallel_stop
          i = opts[k].to_i
          error!("#{k} has to be greater than 0") if i < 1

          changes[k] = i

        when :attrs
          changes[k] = v
        end
      end

      pool.set(changes) if changes.any?

      ok
    end
  end
end
