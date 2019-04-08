require 'singleton'
require 'osctld/lockable'

module OsCtld
  # Registry for user/group IDs allocated to dynamic users
  class UGidRegistry
    ID_POOL = (100000..199999)

    include Singleton
    include Lockable

    class << self
      def setup
        instance
      end

      %i(<< remove taken? get export).each do |v|
        define_method(v) { |*args| instance.send(v, *args) }
      end
    end

    def initialize
      init_lock
      @allocated = []
      @free = ID_POOL.to_a
    end

    # @param ugid [Integer]
    # @return [Boolean]
    def in_range?(ugid)
      ugid >= ID_POOL.begin && ugid <= ID_POOL.end
    end

    # @param ugid [Integer]
    # @return [UGidRegistry]
    def <<(ugid)
      return self unless in_range?(ugid)

      exclusively do
        next if taken?(ugid)
        @free.delete(ugid)
        insert_sort(@allocated, ugid)
      end

      self
    end

    # @param ugid [Integer]
    # @return [Integer, nil]
    def remove(ugid)
      return unless in_range?(ugid)

      exclusively do
        unless taken?(ugid)
          raise ArgumentError, "ugid #{ugid} is not registered"
        end

        @allocated.delete(ugid)
        insert_sort(@free, ugid)
      end

      ugid
    end

    # @param ugid [Integer]
    # @return [Boolean]
    def taken?(ugid)
      inclusively do
        @allocated.bsearch { |v| v >= ugid } == ugid
      end
    end

    # @return [Integer] allocated user/group ID
    def get
      exclusively { @free.shift }
    end

    def export
      inclusively do
        {
          allocated: @allocated.clone,
          free: @free.clone,
        }
      end
    end

    protected
    def insert_sort(arr, i)
      index = arr.bsearch_index { |v| v >= i }

      if index.nil?
        arr << i

      elsif arr[index] > i
        arr.insert(index, i)

      else
        raise ArgumentError, "array already includes #{i}"
      end

      arr
    end
  end
end
