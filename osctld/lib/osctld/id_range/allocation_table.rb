module OsCtld
  class IdRange::AllocationTable
    Allocation = Struct.new(:index, :count, :owner) do
      def self.load(data)
        new(data['index'], data['count'], data['owner'])
      end

      def last_index
        index + count - 1
      end

      def dump
        to_h.to_h { |k, v| [k.to_s, v] }
      end

      def export
        {
          block_index: index,
          block_count: count,
          owner:
        }
      end
    end

    def self.load(block_count, data)
      t = new(block_count)

      data.each do |v|
        allocation = Allocation.load(v)
        t.allocate_at(allocation.index, allocation.count, allocation.owner)
      end

      t
    end

    # @return [Integer]
    attr_reader :block_count

    # @param block_count [Integer]
    def initialize(block_count)
      @block_count = block_count
      @table = []
    end

    # Check if blocks at specified position are free
    # @param index [Integer] block index
    # @param count [Integer] number of blocks from `index` that have to be free
    # @return [Boolean]
    def free_at?(index, count)
      last_index = index + count - 1

      free_segments(count).each do |_, free_index, free_count|
        last_free_index = free_index + free_count - 1

        if index >= free_index && last_index <= last_free_index
          return true
        elsif free_index > last_index
          return false
        end
      end

      false
    end

    # Allocate blocks on a specific position
    # @param index [Integer] block index
    # @param count [Integer] number of blocks
    # @param owner [String] arbitrary allocation owner
    # @return [Hash, false]
    def allocate_at(index, count, owner)
      alloc = Allocation.new(index, count, owner)

      if table.empty?
        table << alloc
        return alloc.export

      elsif !free_at?(index, count)
        raise ArgumentError, "unable to allocate #{count} blocks at #{index}"
      end

      table.each_with_index do |v, t_i|
        if v.index > index
          table.insert(t_i, alloc)
          return alloc.export
        end
      end

      table << alloc
      alloc.export
    end

    # Allocate blocks anywhere in the table
    # @param count [Integer] number of blocks
    # @param owner [String] arbitrary allocation owner
    # @return [Hash, false]
    def allocate(count, owner)
      free_segments(count).each do |table_index, block_index, _count|
        alloc = Allocation.new(block_index, count, owner)
        table.insert(table_index, alloc)
        return alloc.export
      end

      false
    end

    # Free allocation starting at a specified position
    # @param index [Integer] block index
    # @return [Boolean]
    def free_at(index)
      table.each_with_index do |alloc, t_i|
        if alloc.index == index
          table.delete_at(t_i)
          return true
        end
      end

      false
    end

    # Free one allocation which is owned by `owner`
    # @param owner [String]
    # @return [Boolean]
    def free_by(owner)
      table.delete_if.with_index do |alloc, _t_i|
        alloc.owner == owner
      end

      true
    end

    # @return [Integer]
    def count_allocated_blocks
      table.inject(0) { |sum, v| sum + v.count }
    end

    # @return [Integer]
    def count_free_blocks
      free_segments.inject(0) do |sum, v|
        _, _, count = v
        sum + count
      end
    end

    # @return [Boolean]
    def empty?
      table.empty?
    end

    def dump
      table.map(&:dump)
    end

    def export_all
      all_segments.map do |type, _table_index, block_index, count, owner|
        {
          type:,
          block_index:,
          block_count: count,
          owner:
        }
      end
    end

    def export_allocated
      table.map(&:export)
    end

    def export_free
      free_segments.map do |_table_index, block_index, count|
        {
          block_index:,
          block_count: count
        }
      end
    end

    # @param index [Integer] block index
    def export_at(index)
      all_segments.each do |type, _table_index, block_index, count, owner|
        if index >= block_index && index <= (block_index + count - 1)
          return {
            type:,
            block_index:,
            block_count: count,
            owner:
          }
        end
      end

      raise ArgumentError, 'index out of range'
    end

    protected

    attr_reader :table

    # Iterate over allocated and free segments in the table
    # @yieldparam type [:allocated, :free]
    # @yieldparam table_index [Integer] index in @table
    # @yieldparam block_index [Integer] index of the block in the entire
    #                                   allocation table
    # @yieldparam count [Integer] number of free blocks at this position
    # @yieldparam owner [String]
    # @return [Enumerator]
    def all_segments
      Enumerator.new do |yielder|
        if table.empty?
          yielder << [:free, 0, 0, block_count, nil]
          next
        end

        t_i = 0

        # Check if there is space before the first allocation
        free = table.first.index
        yielder << [:free, t_i, 0, free, nil] if free > 0

        loop do
          next_t_i = t_i + 1
          a1 = table[t_i]
          a2 = table[next_t_i]

          # Yield allocated block
          yielder << [:allocated, t_i, a1.index, a1.count, a1.owner]

          if a2.nil?
            # a1 is the last allocation, check if there is free space behind it
            free_count = block_count - a1.last_index - 1

            if free_count > 0
              yielder << [:free, next_t_i, a1.last_index + 1, free_count, nil]
            end

            break
          end

          # Report free space between a1 and a2
          free = a2.index - a1.last_index - 1
          yielder << [:free, next_t_i, a1.last_index + 1, free, nil] if free > 0

          t_i = next_t_i
        end
      end
    end

    # Iterate over free segments in the table
    # @param count [Integer] specify a minimum free segment size, i.e. a number
    #                        of blocks
    # @yieldparam table_index [Integer] index in @table
    # @yieldparam block_index [Integer] index of the block in the entire
    #                                   allocation table
    # @yieldparam count [Integer] number of free blocks at this position
    # @return [Enumerator]
    def free_segments(count = 1)
      all_segments.select do |type, _, _, cnt|
        type == :free && cnt >= count
      end.map do |_type, t_i, b_i, cnt|
        [t_i, b_i, cnt]
      end
    end
  end
end
