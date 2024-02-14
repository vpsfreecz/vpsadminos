module OsCtl::Lib
  # Read interface to /proc/spl/kstat/zfs/<pool>/txgs
  class Zfs::ZpoolTransactionGroups
    PROC_PATH = '/proc/spl/kstat/zfs'

    STATES = {
      'B' => :birth,
      'O' => :open,
      'Q' => :quiesced,
      'W' => :wait_for_sync,
      'S' => :synced,
      'C' => :committed,
      '?' => :unknown
    }

    # @!attribute [r] pool
    #   @return [String] Pool name
    # @!attribute [r] txg
    #   @return [Integer] Transaction group name
    # @!attribute [r] birth_time
    #   @return [Time] Birth time
    # @!attribute [r] birth_ns
    #   @return [Integer] Time of birth in ns since boot
    # @!attribute [r] state
    #   @return [Symbol] Transaction state
    # @!attribute [r] ndirty
    #   @return [Integer] Number of dirty bytes
    # @!attribute [r] nread
    #   @return [Integer] Number of bytes read
    # @!attribute [r] nwritten
    #   @return [Integer] Number of bytes written
    # @!attribute [r] reads
    #   @return [Integer] Number of read operations
    # @!attribute [r] writes
    #   @return [Integer] Number of write operations
    # @!attribute [r] otime_ns
    #   @return [Integer] Time for which the txg was open in ns
    # @!attribute [r] qtime_ns
    #   @return [Integer] Time for which the txg was quiescesing in ns
    # @!attribute [r] wtime_ns
    #   @return [Integer] Time for which the txg was waiting for sync in ns
    # @!attribute [r] stime_ns
    #   @return [Integer] Time for which the txg was syncing in ns
    TransactionGroup = Struct.new(
      :pool,
      :txg,
      :birth_time,
      :birth_ns,
      :state,
      :ndirty,
      :nread,
      :nwritten,
      :reads,
      :writes,
      :otime_ns,
      :qtime_ns,
      :wtime_ns,
      :stime_ns,
      keyword_init: true
    ) do
      def open?
        state == :open
      end

      def committed?
        state == :committed
      end
    end

    class TransactionGroupList
      def initialize
        @list = []
        @index = {}
      end

      # @param txg [TransactionGroup]
      def <<(txg)
        @list << txg
        @index[txg.txg] = txg
      end

      # @yieldparam [TransactionGroup]
      def each(&)
        @list.each(&)
      end

      # @return [TransactionGroup, nil]
      def last
        @list.last
      end

      # @return [TransactionGroup, nil]
      def last_committed
        @list.reverse_each do |txg|
          return txg if txg.committed?
        end

        nil
      end

      # @return [TransactionGroup]
      def opened
        txg = @list.last
        raise 'expected the last txg to be open' unless txg.open?

        txg
      end

      # @return [Integer]
      def length
        @list.length
      end

      # List transaction groups since older list
      # @param other [TransactionGroupList]
      # @param changed [Boolean] include the last txg if its state has changed
      # @return [TransactionGroupList]
      def since(other, changed: false)
        last_txg = other.last
        return self if last_txg.nil? || !@index.has_key?(last_txg.txg)

        ret = self.class.new
        add = false

        @list.each do |txg|
          if txg.txg == last_txg.txg
            add = true
            next if !changed || txg.state == last_txg.state
          end

          ret << txg if add
        end

        ret
      end
    end

    # @return [Hash<String, TransactionGroupList>]
    attr_reader :pools

    # @param pools [Array<String>]
    def initialize(pools: [])
      read_pools = pools.empty? ? list_pools : pools
      paths = read_pools.to_h { |pool| [pool, txgs_path(pool)] }

      @pools = read_paths(paths)
    end

    # @yieldparam [String] pool name
    # @yieldparam [TransactionGroupList] transaction groups
    def each(&)
      @pools.each(&)
    end

    protected

    def read_paths(txgs_paths)
      ret = {}
      uptime = Uptime.new

      txgs_paths.each do |pool, txgs_path|
        ret[pool] = read_file(pool, txgs_path, uptime)
      end

      ret
    end

    def read_file(pool, txgs_path, uptime)
      ret = TransactionGroupList.new

      File.open(txgs_path) do |f|
        it = f.each_line
        it.next # skip the header
        it.each do |line|
          values = line.strip.split

          birth_ns = values[1].to_i
          birth_time = uptime.booted_at + (birth_ns / 1_000_000_000.to_f)

          ret << TransactionGroup.new(
            pool:,
            txg: values[0].to_i,
            birth_time:,
            birth_ns:,
            state: STATES[values[2]],
            ndirty: values[3].to_i,
            nread: values[4].to_i,
            nwritten: values[5].to_i,
            reads: values[6].to_i,
            writes: values[7].to_i,
            otime_ns: values[8].to_i,
            qtime_ns: values[9].to_i,
            wtime_ns: values[10].to_i,
            stime_ns: values[11].to_i
          )
        end
      end

      ret
    end

    def list_pools
      ret = []

      Dir.entries(PROC_PATH).each do |f|
        next if %w[. ..].include?(f)
        next unless Dir.exist?(File.join(PROC_PATH, f))

        ret << f
      end

      ret
    end

    def txgs_path(pool)
      File.join(PROC_PATH, pool, 'txgs')
    end
  end
end
