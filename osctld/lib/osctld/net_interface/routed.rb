require 'ipaddress'
require 'osctld/net_interface/veth'

module OsCtld
  class NetInterface::Routed < NetInterface::Veth
    type :routed

    extend OsCtl::Lib::Utils::System
    extend Utils::Ip

    INTERFACE = 'osrtr0'.freeze
    DEFAULT_IPV4 = IPAddress.parse('172.31.255.254/32')
    DEFAULT_IPV6 = IPAddress.parse('fe80::1/64')

    def self.setup
      begin
        ip(:all, [:link, :show, :dev, INTERFACE])
      rescue SystemCommandFailed => e
        raise if e.rc != 1 # interface exists

        ip(:all, [:link, :add, INTERFACE, :type, :dummy])
      end

      [DEFAULT_IPV4.to_string, '255.255.255.254/32'].each do |addr|
        ip(4, [:addr, :add, addr, :dev, INTERFACE])
      rescue SystemCommandFailed => e
        raise if e.rc != 2 # address already assigned
      end
    end

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
        'routes' => @routes.dump
      })
    end

    def set(opts)
      orig_enable = enable

      super

      # rubocop:disable Style/GuardClause

      if veth && opts.has_key?(:enable) && opts[:enable] && !orig_enable
        [4, 6].each do |v|
          next if @routes.empty?(v)

          @routes.each_version(v) do |route|
            ip(v, %i[route add] + route.ip_spec + [:dev, veth])
          end
        end
      end

      # rubocop:enable Style/GuardClause
    end

    def setup
      super

      return if ct.fresh_state != :running

      iplist = ip(:all, [:addr, :show, :dev, veth], valid_rcs: [1])

      return unless iplist.exitstatus == 1

      log(
        :info,
        ct,
        "veth '#{veth}' of container '#{ct.id}' no longer exists, " \
        'ignoring'
      )
      @veth = nil
      nil
    end

    def up(veth)
      super

      if enable
        [4, 6].each do |v|
          next if @routes.empty?(v)

          @routes.each_version(v) do |route|
            ip(v, %i[route add] + route.ip_spec + [:dev, veth])
          end
        end

        ip(6, %i[addr add] + [DEFAULT_IPV6.to_string] + [:dev, veth])
      end

      File.write(File.join('/proc/sys/net/ipv4/conf', veth, 'rp_filter'), '1')
    end

    # DistConfig can be run only after the interface has been created
    def can_run_distconfig?
      exclusively { !veth.nil? }
    end

    def add_ip(addr, route)
      super(addr)

      v = addr.ipv4? ? 4 : 6
      r = @routes.add(route) if route && !@routes.contains?(route)

      ct.inclusively do
        next if ct.state != :running

        # Add host route
        ip(v, %i[route add] + r.ip_spec + [:dev, veth]) if r && enable

        # Add IP within the CT
        ct_syscmd(
          ct,
          ['ip', "-#{v}", 'addr', 'add', addr.to_string, 'dev', name],
          valid_rcs: [2]
        )

        # Ensure the default route exists
        via = default_via(v)

        ct_syscmd(
          ct,
          ['ip', "-#{v}", 'route', 'add', via.to_s, 'dev', name],
          valid_rcs: [2]
        )
        ct_syscmd(
          ct,
          ['ip', "-#{v}", 'route', 'add', 'default', 'via', via.to_s, 'dev', name],
          valid_rcs: [2]
        )
      end
    end

    def del_ip(addr, keep_route)
      super(addr)

      routes_to_remove = []
      v = addr.ipv4? ? 4 : 6

      unless keep_route
        r = @routes.remove(addr)
        routes_to_remove << r if r
      end

      # Remove all routes that are routed _via_ `addr`
      @routes.remove_version_if(v) do |route|
        if route.via && route.via.to_s == addr.to_s
          routes_to_remove << route
          true
        else
          false
        end
      end

      ct.inclusively do
        next if ct.state != :running

        # Remove host route
        if enable
          routes_to_remove.each do |route|
            ip(v, %i[route del] + route.ip_spec + [:dev, veth])
          end
        end

        # Remove IP from within the CT
        ct_syscmd(
          ct,
          ['ip', "-#{v}", 'addr', 'del', addr.to_string, 'dev', name],
          valid_rcs: [2]
        )
      end
    end

    # @param ip_v [Integer, nil]
    def del_all_ips(ip_v, keep_routes)
      exclusively do
        (ip_v ? [ip_v] : [4, 6]).each do |v|
          @ips[v].clone.each { |addr| del_ip(addr, keep_routes) }
        end
      end
    end

    def has_route?(addr)
      @routes.contains?(addr)
    end

    def add_route(addr, via: nil)
      route = @routes.add(addr, via:)
      return unless enable

      ct.inclusively do
        next if ct.state != :running

        ip(route.ip_version, %i[route add] + route.ip_spec + [:dev, veth])
      end
    end

    def del_route(addr)
      route = @routes.remove(addr)
      return if !route || !enable

      ct.inclusively do
        next if ct.state != :running

        ip(route.ip_version, %i[route del] + route.ip_spec + [:dev, veth])
      end
    end

    # @param ip_v [Integer, nil]
    def del_all_routes(ip_v = nil)
      removed = @routes.remove_all(ip_v)
      return unless enable

      ct.inclusively do
        next if ct.state != :running

        removed.each do |route|
          ip(route.ip_version, %i[route del] + route.ip_spec + [:dev, veth])
        end
      end
    end

    # @param v [4, 6] IP version
    # @return [IPAddress::IPv4, IPAddress::IPv6]
    def default_via(v)
      case v
      when 4
        DEFAULT_IPV4
      when 6
        DEFAULT_IPV6
      end
    end
  end
end
