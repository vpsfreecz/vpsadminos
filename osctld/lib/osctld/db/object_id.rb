module OsCtld
  # Represents object id for lookup
  #
  # Object id can be given with or without pool name. Pool name can also be given
  # as a separate option, but it does not override pool name from the id itself.
  class DB::ObjectId
    # @return [String, Array<String>, nil]
    attr_reader :pool

    # @return [String]
    attr_reader :id

    # @param id [String]
    # @param pool [String, Array<String>, Pool, nil]
    def initialize(id, pool = nil)
      if i = id.index(':')
        @pool = id[0..i-1]
        @id = id[i+1..-1]
      else
        @id = id
      end

      if pool && @pool.nil?
        @pool =
          if pool.is_a?(Pool)
            pool.name
          elsif pool.is_a?(String) || pool.is_a?(Array)
            pool
          else
            fail "invalid pool type '#{pool.class}', expected OsCtld::Pool or String"
          end
      end
    end

    # Check if objects matches id
    # @param obj [#pool, #id]
    def match?(obj)
      if @pool.nil?
        obj.id == @id
      elsif @pool.is_a?(Array)
        obj.id == @id && @pool.include?(obj.pool.name)
      else
        obj.pool.name == @pool && obj.id == @id
      end
    end
  end
end
