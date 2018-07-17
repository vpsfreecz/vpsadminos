require 'ipaddress'
require 'osctld/net_interface/veth'

module OsCtld
  class NetInterface::Routed < NetInterface::Veth
    type :routed

    include Utils::Ip

    attr_reader :via, :routes

    # @param opts [Hash]
    # @option opts [String] name
    # @option opts [String] via
    def create(opts)
      super

      @via = Hash[ opts[:via].map do |k, v|
        net_addr = IPAddress.parse(v[:network])
        [
          k,
          Routing::Via.for(net_addr).new(
            net_addr,
            v[:host_addr] && IPAddress.parse(v[:host_addr]),
            v[:ct_addr] && IPAddress.parse(v[:ct_addr]),
          )
        ]
      end]

      @routes = Routing::Table.new
    end

    def load(cfg)
      super

      @via = load_ip_list(cfg['via'] || {}) do |v|
        Routing::Via.load(v)
      end

      @routes = Routing::Table.load(cfg['routes'] || {})
    end

    def save
      super.merge({
        'via' => save_ip_list(@via) { |v| v.dump },
        'routes' => @routes.dump,
      })
    end

    # @param opts [Hash] options
    # @option opts [Hash<Integer, Hash>] :via
    def set(opts)
      super

      if opts[:via]
        @via = Hash[ opts[:via].map do |ip_v, net|
          [
            ip_v,
            Routing::Via.for(net[:network]).new(
              net[:network],
              net[:host_addr],
              net[:ct_addr],
            )
          ]
        end]
      end
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
        next if @routes.empty?(v)

        setup_routing(v) unless @host_setup[v]

        @routes.each_version(v) do |addr|
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

    def add_ip(addr, route)
      super(addr)
      @routes << route if route && !@routes.contains?(route)

      v = addr.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        setup_routing(v) unless @host_setup[v]

        # Add host route
        if route
          ip(v, [
            :route, :add,
            route.to_string, :via, via[v].ct_ip.to_s, :dev, veth
          ])
        end

        # Add IP within the CT
        ct_syscmd(
          ct,
          "ip -#{v} addr add #{addr.to_string} dev #{name}",
          valid_rcs: [2]
        )
      end
    end

    def del_ip(addr, keep_route)
      super(addr)
      route = @routes.remove(addr) unless keep_route

      v = addr.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        # Remove host route
        if route
          ip(v, [
            :route, :del,
            route.to_string, :via, via[v].ct_ip.to_s, :dev, veth
          ])
        end

        # Remove IP from within the CT
        ct_syscmd(
          ct,
          "ip -#{v} addr del #{addr.to_string} dev #{name}",
          valid_rcs: [2]
        )
      end
    end

    # @param ip_v [Integer, nil]
    def del_all_ips(ip_v, keep_routes)
      (ip_v ? [ip_v] : [4, 6]).each do |v|
        @ips[v].clone.each { |addr| del_ip(addr, keep_routes) }
      end
    end

    def can_route_ip?(addr)
      !@via[addr.ipv4? ? 4 : 6].nil?
    end

    def has_route?(addr)
      @routes.contains?(addr)
    end

    def add_route(addr)
      @routes << addr
      v = addr.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        ip(v, [
          :route, :add,
          addr.to_string, :via, via[v].ct_ip.to_s, :dev, veth
        ])
      end
    end

    def del_route(addr)
      route = @routes.remove(addr)
      return unless route
      v = route.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        ip(v, [
          :route, :del,
          route.to_string, :via, via[v].ct_ip.to_s, :dev, veth
        ])
      end
    end

    # @param ip_v [Integer, nil]
    def del_all_routes(ip_v = nil)
      removed = @routes.remove_all(ip_v)

      ct.inclusively do
        next if ct.state != :running

        removed.each do |route|
          v = route.ipv4? ? 4 : 6

          ip(v, [
            :route, :del,
            route.to_string, :via, via[v].ct_ip.to_s, :dev, veth
          ])
        end
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
