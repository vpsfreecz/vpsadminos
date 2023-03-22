require 'osctld/db/list'

module OsCtld
  class DB::PooledList < DB::List
    class << self
      %i(select_by_ids each_by_ids).each do |v|
        define_method(v) do |*args, **kwargs, &block|
          instance.send(v, *args, **kwargs, &block)
        end
      end
    end

    # Find object by `id` and `pool`.
    #
    # There are two ways to specify a pool:
    #   - use the `pool` argument
    #   - when `pool` is `nil` and `id` contains a colon, it is parsed as
    #     `<pool>:<id>`
    #
    # @param id [String]
    # @param pool [String, Pool, nil]
    # @yieldparam [any] object
    # @return [any]
    def find(id, pool = nil, &block)
      obj_id = DB::ObjectId.new(id, pool)

      sync do
        obj = objects.detect { |v| obj_id.match?(v) }

        if block
          block.call(obj)
        else
          obj
        end
      end
    end

    # @param id [String]
    # @param pool [String, Pool, nil]
    def contains?(id, pool = nil)
      !find(id, pool).nil?
    end

    # Select objects matching ids and pool
    # @param ids [Array<String>, nil]
    # @param pool [String, Pool, nil]
    # @yieldparam [any] object
    # @yieldreturn [Boolean] select the object or not
    # @return [Array]
    def select_by_ids(ids, pool = nil, &block)
      if ids.nil?
        if block
          return get.each(&block)
        else
          return get
        end
      end

      obj_ids = ids.map{ |id| DB::ObjectId.new(id, pool) }

      get.select do |obj|
        next(false) if obj_ids.detect { |obj_id| obj_id.match?(obj) }.nil?

        if block
          block.call(obj)
        else
          true
        end
      end
    end

    # Iterate objects matching ids and pool
    # @param ids [Array<String>, nil]
    # @param pool [String, Pool, nil]
    # @yieldparam [any] object
    def each_by_ids(ids, pool = nil)
      select_by_ids(ids, pool) do |obj|
        yield(obj)
        false
      end

      nil
    end
  end
end
