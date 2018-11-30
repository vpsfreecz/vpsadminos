module OsCtl::Lib
  # Hash-based cache for collection lookups by key
  #
  # {Index} is not thread-safe.
  class Index
    # @yieldparam obj [Object] the indexed object
    # @yieldreturn [String] key for the indexed object
    def initialize(&block)
      @block = block
      @index = {}
    end

    # Add object to the index
    # @param obj [Object]
    def <<(obj)
      @index[key(obj)] = obj
      self
    end

    # Lookup using string key
    # @param key [String]
    def [](key)
      @index[key]
    end

    # Delete object from the index
    # @param obj [Object]
    def delete(obj)
      @index.delete(key(obj))
    end

    # Delete object from the index by key
    # @param key [String]
    def delete_key(key)
      @index.delete(key)
    end

    def empty?
      @index.empty?
    end

    protected
    def key(obj)
      @block.call(obj)
    end
  end
end
