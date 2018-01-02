module OsCtld
  class DB::PooledList < DB::List
    # Find object by `id` and `pool`.
    #
    # There are two ways to specify a pool:
    #   - use the `pool` argument
    #   - when `pool` is `nil` and `id` contains a colon, it is parsed as
    #     `<pool>:<id>`
    def find(id, pool = nil, &block)
      if pool.nil? && id.index(':')
        pool, id = id.split(':')
      end

      sync do
        obj = objects.detect do |v|
          next if v.id != id
          next(true) if pool.nil?

          if pool.is_a?(Pool)
            v.pool.name == pool.name

          elsif pool.is_a?(String)
            v.pool.name == pool

          else
            fail "invalid pool type '#{pool.class}', extected OsCtld::Pool or String"
          end
        end

        if block
          block.call(obj)
        else
          obj
        end
      end
    end

    def contains?(id, pool = nil)
      !find(id, pool).nil?
    end
  end
end
