module OsCtl::Lib
  # Read interface to zpool status
  class Zfs::ZpoolStatus
    # @!attribute [r] name
    #   @return [String] pool name
    # @!attribute [r] state
    #   @return [:online, :degraded, :suspended, :faulted] pool state
    # @!attribute [r] scan
    #   @return [:none, :scrub, :resilver] active scan type
    Pool = Struct.new(:name, :state, :scan, keyword_init: true)

    include Utils::Log
    include Utils::System

    # @return [Array<Pool>]
    attr_reader :pools

    # @param pools [Array<String>] pools to query, all pools are queried if empty
    def initialize(pools: [])
      @pools, @index = read(pools)
    end

    # @param name [String] pool name
    # @return [Pool, nil]
    def [](name)
      @index[name]
    end

    protected
    def read(pools)
      list = []
      index = {}

      cur_pool = nil

      syscmd("zpool status #{pools.join(' ')}").output.strip.each_line do |line|
        stripped = line.strip

        if stripped.start_with?('pool:')
          if cur_pool
            list << cur_pool
            index[cur_pool.name] = cur_pool
          end

          cur_pool = Pool.new(
            name: stripped[5..-1].strip,
            state: :unknown,
            scan: :none,
          )

        elsif stripped.start_with?('state:')
          cur_pool.state = stripped[6..-1].strip.downcase.to_sym

        elsif stripped.start_with?('scan:')
          scan = stripped[5..-1].strip

          cur_pool.scan =
            if scan.start_with?('resilver in progress')
              :resilver
            elsif scan.start_with?('scrub in progress')
              :scrub
            else
              :none
            end
        end
      end

      if cur_pool
        list << cur_pool
        index[cur_pool.name] = cur_pool
      end

      [list, index]
    end
  end
end
