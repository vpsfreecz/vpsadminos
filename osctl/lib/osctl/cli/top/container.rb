module OsCtl::Cli
  class Top::Container
    NetIf = Struct.new(:name, :veth, :stats) do
      def initialize(netif)
        self.name = netif[:name]
        self.veth = netif[:veth]
      end
    end

    attr_reader :id, :pool, :dataset, :group_path
    attr_accessor :state, :netifs

    # @param ct [Hash] container from ct_show
    def initialize(ct)
      @id = ct[:id]
      @pool = ct[:pool]
      @dataset = ct[:dataset]
      @group_path = ct[:group_path]
      @state = ct[:state].to_sym
      @netifs = []
      @measurements = []
      @initial = nil
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
      m = Top::Measurement.new(host, subsystems, group_path, dataset, netifs)
      m.measure
      @initial = m if measurements.empty?
      measurements << m
      measurements.shift if measurements.size > 2
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
