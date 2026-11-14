module OsCtl::Cli
  class Top::Container
    NetIf = Struct.new(:name, :veth, :stats) do
      def initialize(netif)
        self.name = netif[:name]
        self.veth = netif[:veth]
      end
    end

    attr_reader :id, :pool, :ident, :dataset, :group_path
    attr_accessor :state, :cpu_package_inuse, :init_pid, :netifs, :init_start_time_ticks

    # @param ct [Hash] container from ct_show
    def initialize(ct = nil, enable_netif: true, enable_zfs: true, **attrs)
      ct ||= attrs
      @enable_netif = enable_netif
      @enable_zfs = enable_zfs
      @id = ct[:id]
      @pool = ct[:pool]
      @ident = "#{@pool}:#{@id}"
      @dataset = ct[:dataset]
      @group_path = ct[:group_path]
      @state = ct[:state].to_sym
      @cpu_package_inuse = ct[:cpu_package_inuse]
      @init_pid = ct[:init_pid]
      @netifs = []
      @measurements = []
      @initial = nil
    end

    def [](k)
      # Used by OsCtl::Lib::LoadAvgReader
      case k
      when :id
        @id
      when :pool
        @pool
      when :init_pid
        @init_pid
      else
        raise ArgumentError, "key #{k.inspect} is not supported"
      end
    end

    def setup?
      measurements.count >= 2
    end

    def running?
      @state == :running
    end

    def container?
      true
    end

    def measure(host, subsystems)
      m = Top::Measurement.new(host, subsystems, group_path, dataset, netifs,
                               enable_netif: @enable_netif, enable_zfs: @enable_zfs)
      m.measure
      @initial = m if measurements.empty?
      measurements << m
      measurements.shift if measurements.size > 2
    end

    def snapshot
      copy = dup
      copy.instance_variable_set(:@measurements, measurements.dup)
      copy.netifs = netifs == :all ? :all : netifs.map(&:dup)
      copy
    end

    def update(ct)
      reset_measurements if group_path != ct[:group_path] || init_pid != ct[:init_pid] || state != ct[:state].to_sym
      @dataset = ct[:dataset]
      @group_path = ct[:group_path]
      @state = ct[:state].to_sym
      @init_pid = ct[:init_pid]
      @cpu_package_inuse = ct[:cpu_package_inuse]
    end

    def reset_measurements(keep_current: false)
      @measurements = keep_current && !measurements.empty? ? [measurements.last] : []
      @initial = @measurements.first
    end

    def current_measurement
      measurements.last
    end

    def core_delta_error
      return 'initial_baseline' unless setup?

      current_measurement.delta_error(measurements[-2])
    end

    def result(mode)
      case mode
      when :realtime
        measurements[1].diff_from(measurements[0], mode)

      when :cumulative
        measurements[1].diff_from(initial, mode)
      end
    end

    def netif_up(name, veth)
      netif = find_netif(name)
      netif.veth = veth
    end

    def netif_down(name)
      netif = find_netif(name)
      netif.veth = nil
    end

    def netif_rm(name)
      netif = find_netif(name)
      netifs.delete(netif)
    end

    def netif_rename(name, new_name)
      netif = find_netif(name)
      netif.name = new_name
    end

    def has_netif?(name)
      !find_netif(name).nil?
    end

    protected

    attr_reader :measurements, :initial

    def find_netif(name)
      netifs.detect { |netif| netif.name == name }
    end
  end
end
