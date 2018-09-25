require 'ipaddress'
require 'osctld/net_interface/veth'

module OsCtld
  class NetInterface::Routed < NetInterface::Veth
    type :routed

    extend OsCtl::Lib::Utils::System
    extend Utils::Ip

    INTERFACE = 'osrtr0'
    DEFAULT_IPS = {
      4 => IPAddress.parse('255.255.255.254/32'),
      6 => IPAddress.parse('fe80:ffff:ffff:ffff:ffff:ffff:ffff:fffe/128'),
    }

    def self.setup
      begin
        ip(:all, [:link, :show, :dev, INTERFACE])
        return

      rescue SystemCommandFailed => e
        raise if e.rc != 1
      end

      ip(:all, [:link, :add, INTERFACE, :type, :dummy])

      [4, 6].each do |ip_v|
        ip(ip_v, [:addr, :add, DEFAULT_IPS[ip_v].to_string, :dev, INTERFACE])
      end
    end

    include Utils::Ip

    attr_reader :routes

    # @param opts [Hash]
    # @option opts [String] name
    def create(opts)
      super

      @routes = Routing::Table.new
    end

    def load(cfg)
      super

      @routes = Routing::Table.load(cfg['routes'] || {})
    end

    def save
      super.merge({
        'routes' => @routes.dump,
      })
    end

    def setup
      super

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
    end

    def up(veth)
      super

      [4, 6].each do |v|
        next if @routes.empty?(v)

        @routes.each_version(v) do |addr|
          ip(v, [:route, :add, addr.to_string, :dev, veth])
        end
      end
    end

    def active_ip_versions
      [4, 6].delete_if { |v| @ips[v].empty? }
    end

    def add_ip(addr, route)
      super(addr)

      v = addr.ipv4? ? 4 : 6

      @routes << route if route && !@routes.contains?(route)

      ct.inclusively do
        next if ct.state != :running

        # Add host route
        if route
          ip(v, [:route, :add, route.to_string, :dev, veth])
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
          ip(v, [:route, :del, route.to_string, :dev, veth])
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

    def has_route?(addr)
      @routes.contains?(addr)
    end

    def add_route(addr)
      @routes << addr
      v = addr.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        ip(v, [:route, :add, addr.to_string, :dev, veth])
      end
    end

    def del_route(addr)
      route = @routes.remove(addr)
      return unless route
      v = route.ipv4? ? 4 : 6

      ct.inclusively do
        next if ct.state != :running

        ip(v, [:route, :del, route.to_string, :dev, veth])
      end
    end

    # @param ip_v [Integer, nil]
    def del_all_routes(ip_v = nil)
      removed = @routes.remove_all(ip_v)

      ct.inclusively do
        next if ct.state != :running

        removed.each do |route|
          v = route.ipv4? ? 4 : 6

          ip(v, [:route, :del, route.to_string, :dev, veth])
        end
      end
    end

    def default_via(v)
      DEFAULT_IPS[v]
    end
  end
end
