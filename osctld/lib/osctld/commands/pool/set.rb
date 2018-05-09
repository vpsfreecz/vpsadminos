module OsCtld
  class Commands::Pool::Set < Commands::Logged
    handle :pool_set

    def find
      pool = DB::Pools.find(opts[:name])
      pool || error!('pool not found')
    end

    def execute(pool)
      pool.exclusively do
        changes = {}

        %i(parallel_start parallel_stop).each do |k|
          next unless opts[k]

          case k
          when :parallel_start, :parallel_stop
            v = opts[k].to_i
            error!("#{k} has to be greater than 0") if v < 1

            changes[k] = v

          else
            fail 'programming error'
          end
        end

        pool.set(changes) if changes.any?
      end

      ok
    end
  end
end
