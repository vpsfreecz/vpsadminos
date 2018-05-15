require 'ipaddress'
require 'osctld/net_interface/veth'

module OsCtld
  class NetInterface::Routed < NetInterface::Veth
    type :routed

    include Utils::Ip

    attr_reader :via

    # @param opts [Hash]
    # @option opts [String] name
    # @option opts [String] via
    def create(opts)
      super

      @via = Hash[ opts[:via].map do |k, v|
        [k, Routing::Via.for(IPAddress.parse(v))]
      end]
    end

    def load(cfg)
      super

      @via = load_ip_list(cfg['via'] || {}) do |v|
        Routing::Via.for(IPAddress.parse(v))
      end
    end

    def save
      super.merge({
        'via' => save_ip_list(@via) { |v| v.net_addr.to_string },
      })
    end

    def setup
      super
      @host_setup = {}

      return if ct.current_state != :running

      iplist = ip(:all, [:addr, :show, :dev, veth], valid_rcs: [1])

      if iplist[:exitstatus] == 1
        log(
          :info,
          ct,
          "veth '#{veth}' of container '#{ct.id}' no longer exists, "+
          "ignoring"
        )
        @veth = nil
        return
      end

      [4, 6].each do |ip_v|
        net = via[ip_v]
        next unless net

        inet = ip_v == 4 ? 'inet' : 'inet6'

        if /#{inet} #{Regexp.escape(net.host_ip.to_string)}/ =~ iplist[:output]
          log(
            :info,
            ct,
            "Discovered IPv#{ip_v} configuration for routed veth #{name}"
          )

          @host_setup[ip_v] = true
        end
      end
    end

    def up(veth)
      super

      [4, 6].each do |v|
        next if @ips[v].empty?

        setup_routing(v) unless @host_setup[v]

        @ips[v].each do |addr|
          ip(v, [
            :route, :add,
            addr.to_string, :via, via[v].ct_ip.to_s, :dev, veth
          ])
        end
      end
    end

    def down(veth)
      super
      @host_setup = {}
    end

    def can_add_ip?(addr)
      !@via[addr.ipv4? ? 4 : 6].nil?
    end

    def active_ip_versions
      [4, 6].delete_if { |v| @via[v].nil? }
    end

    def add_ip(addr)
      super

      v = addr.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        setup_routing(v) unless @host_setup[v]

        # Add host route
        ip(v, [
          :route, :add,
          addr.to_string, :via, via[v].ct_ip.to_s, :dev, veth
        ])

        # Add IP within the CT
        ct_syscmd(
          ct,
          "ip -#{v} addr add #{addr.to_string} dev #{name}",
          valid_rcs: [2]
        )
      end
    end

    def del_ip(addr)
      super

      v = addr.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        # Remove host route
        ip(v, [
          :route, :del,
          addr.to_string, :via, via[v].ct_ip.to_s, :dev, veth
        ])

        # Remove IP from within the CT
        ct_syscmd(
          ct,
          "ip -#{v} addr del #{addr.to_string} dev #{name}",
          valid_rcs: [2]
        )
      end
    end

    protected
    def setup_routing(v)
      unless veth
        fail "Unable to setup routing for IPv#{v}: name of the veth "+
             "interface is not known"
      end

      ip(v, [:addr, :add, via[v].host_ip.to_string, :dev, veth])
      @host_setup[v] = true
    end
  end
end
