module OsCtl::Lib
  # Read interface to zpool status
  class Zfs::ZpoolStatus
    # @!attribute [r] name
    #   @return [String] pool name
    # @!attribute [r] state
    #   @return [:online, :degraded, :suspended, :faulted] pool state
    # @!attribute [r] scan
    #   @return [:none, :scrub, :resilver] active scan type
    # @!attribute [r] scan_percent
    #   @return [Float, nil] scrub/resilver progress
    # @!attribute [r] virtual_devices
    #   @return [Array<VirtualDevice>]
    Pool = Struct.new(
      :name,
      :state,
      :scan,
      :scan_percent,
      :virtual_devices,
      keyword_init: true
    )

    # @!attribute [r] role
    #   @return [:storage, :log, :cache]
    # @!attribute [r] name
    #   @return [String] vdev name
    # @!attribute [r] type
    #   @return [String] vdev type, e.g. disk, mirror, raidz, see man zpoolconcepts(7)
    # @!attribute [r] state
    #   @return [Symbol] device state in lower case, see man zpoolconcepts(7)
    # @!attribute [r] read
    #   @return [Integer] number of read errors
    # @!attribute [r] write
    #   @return [Integer] number of write errors
    # @!attribute [r] checksum
    #   @return [Integer] number of checksum errors
    # @!attribute [r] virtual_devices
    #   @return [Array<VirtualDevice>] child virtual devices
    VirtualDevice = Struct.new(
      :role,
      :name,
      :type,
      :state,
      :read,
      :write,
      :checksum,
      :virtual_devices,
      keyword_init: true
    )

    include Utils::Log
    include Utils::System

    # @return [Array<Pool>]
    attr_reader :pools

    # @param pools [Array<String>] pools to query, all pools are queried if empty
    # @param status_string [String] optional output from zpool status to parse
    def initialize(pools: [], status_string: nil)
      @pools, @index = read(pools, status_string)
    end

    # @param name [String] pool name
    # @return [Pool, nil]
    def [](name)
      @index[name]
    end

    protected

    def read(pools, status_string)
      list = []
      index = {}

      cur_pool = nil
      in_config = false
      config_parser = nil

      status_string ||= syscmd("zpool status -LP #{pools.join(' ')}").output

      status_string.strip.each_line do |line|
        stripped = line.strip

        if stripped.start_with?('pool:')
          in_config = false

          if cur_pool
            list << cur_pool
            index[cur_pool.name] = cur_pool
          end

          cur_pool = Pool.new(
            name: stripped[5..].strip,
            state: :unknown,
            scan: :none,
            scan_percent: nil,
            virtual_devices: []
          )

          config_parser = nil

        elsif cur_pool && in_config
          config_parser.parse_line(line, stripped)

        elsif cur_pool && stripped.start_with?('state:')
          cur_pool.state = stripped[6..].strip.downcase.to_sym

        elsif cur_pool && stripped.start_with?('scan:')
          scan = stripped[5..].strip

          cur_pool.scan =
            if scan.start_with?('resilver in progress')
              :resilver
            elsif scan.start_with?('scrub in progress')
              :scrub
            else
              :none
            end

        elsif cur_pool && stripped.start_with?('config:')
          in_config = true
          config_parser = ConfigParser.new(cur_pool)

        elsif cur_pool && cur_pool.scan != :none && /, (\d+\.\d+)% done,/ =~ stripped
          cur_pool.scan_percent = ::Regexp.last_match(1).to_f
        end
      end

      if cur_pool
        list << cur_pool
        index[cur_pool.name] = cur_pool
      end

      [list, index]
    end

    class ConfigParser
      # @param pool [Pool]
      def initialize(pool)
        @pool = pool
        @role = :storage
      end

      # Parse config line from zpool status
      #
      # Lines start with a tab and then we decide based on indent level. Pool
      # name has no indentation, vdev for redundancy is indented by two spaces
      # and leaf vdevs by four spaces. If is replace going on or if there's a
      # spare, leaf vdevs are pushed to a lower level.
      def parse_line(line, stripped)
        return unless line.start_with?("\t")

        indent_level = line[1..][/\A */].size
        vdev, state, read, write, checksum = stripped.split

        if indent_level == 0
          case vdev
          when 'logs'
            @role = :log
          when 'cache'
            @role = :cache
          end
          return
        end

        if indent_level == 2
          @vdev_1st = create_vdev(vdev, state, read, write, checksum)
          @pool.virtual_devices << @vdev_1st
          return
        end

        if indent_level == 4
          @vdev_2nd = create_vdev(vdev, state, read, write, checksum)
          @vdev_1st.virtual_devices << @vdev_2nd
          return
        end

        return unless indent_level == 6

        @vdev_3rd = create_vdev(vdev, state, read, write, checksum)
        @vdev_2nd.virtual_devices << @vdev_3rd
        nil
      end

      def create_vdev(vdev, state, read, write, checksum)
        VirtualDevice.new(
          role: @role,
          name: vdev,
          type: vdev.start_with?('/') ? 'disk' : vdev.split('-').first,
          state: state.downcase.to_sym,
          read: read.to_i,
          write: write.to_i,
          checksum: checksum.to_i,
          virtual_devices: []
        )
      end
    end
  end
end
