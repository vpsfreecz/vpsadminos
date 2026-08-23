require 'ipaddress'
require 'json'
require 'osctld/net_interface/veth'

module OsCtld
  class NetInterface::Routed < NetInterface::Veth
    type :routed

    extend OsCtl::Lib::Utils::System
    extend Utils::Ip

    INTERFACE = 'osrtr0'.freeze
    DEFAULT_IPV4 = IPAddress.parse('255.255.255.254/32')
    ROUTE_PROTOCOL = 230
    ROUTE_PROTOCOL_NAME = 'osctld'.freeze

    def self.setup
      begin
        ip(:all, [:link, :show, :dev, INTERFACE])
        return
      rescue SystemCommandFailed => e
        raise if e.rc != 1
      end

      ip(:all, [:link, :add, INTERFACE, :type, :dummy])
      ip(4, [:addr, :add, DEFAULT_IPV4.to_string, :dev, INTERFACE])
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
            ip(v, %i[route add] + owned_route_spec(route))
          end
        end
      end

      # rubocop:enable Style/GuardClause
    end

    def reconcile_runtime(legacy_runtime: false)
      result = super
      return result unless result[:status] == 'healthy'

      [4, 6].each do |version|
        runtime = runtime_routes(version)
        desired_routes = routes.each_version(version).to_a
        desired_routes.each do |route|
          destination_routes = runtime.select do |runtime_route|
            runtime_route_destination_matches?(runtime_route, route)
          end
          present = destination_routes.any? do |runtime_route|
            runtime_route_owned?(runtime_route) \
              && runtime_route_matches?(runtime_route, route)
          end

          if enable
            validate_runtime_route_claim!(route, destination_routes)
            unless present
              claim_runtime_route(version, route, destination_routes)
            end
          else
            destination_routes.each do |entry|
              next unless runtime_route_owned?(entry)

              ip(version, %i[route del] + runtime_route_spec(entry))
            end
          end
        end

        runtime.each do |runtime_route|
          next unless runtime_route_owned?(runtime_route)
          next if desired_routes.any? do |route|
            runtime_route_destination_matches?(runtime_route, route)
          end

          ip(version, %i[route del] + runtime_route_spec(runtime_route))
        end
      end

      File.write(File.join('/proc/sys/net/ipv4/conf', veth, 'rp_filter'), '1')
      result
    rescue StandardError => e
      result.merge(status: 'error', error: "#{e.class}: #{e.message}")
    end

    def up(veth)
      super

      if enable
        [4, 6].each do |v|
          next if @routes.empty?(v)

          @routes.each_version(v) do |route|
            ip(v, %i[route add] + owned_route_spec(route))
          end
        end
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
        ip(v, %i[route add] + owned_route_spec(r)) if r && enable

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
            ip(v, %i[route del] + owned_route_spec(route))
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

        ip(route.ip_version, %i[route add] + owned_route_spec(route))
      end
    end

    def del_route(addr)
      route = @routes.remove(addr)
      return if !route || !enable

      ct.inclusively do
        next if ct.state != :running

        ip(route.ip_version, %i[route del] + owned_route_spec(route))
      end
    end

    # @param ip_v [Integer, nil]
    def del_all_routes(ip_v = nil)
      removed = @routes.remove_all(ip_v)
      return unless enable

      ct.inclusively do
        next if ct.state != :running

        removed.each do |route|
          ip(route.ip_version, %i[route del] + owned_route_spec(route))
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
        get_ipv6_link_local
      end
    end

    def dup(new_ct)
      ret = super
      ret.instance_variable_set('@routes', Routing::Table.load(routes.dump))
      ret
    end

    protected

    def runtime_routes(version)
      JSON.parse(ip(version, %i[-json route show dev] + [veth]).output)
    end

    def runtime_route_matches?(runtime, route)
      return false unless runtime_route_destination_matches?(runtime, route)

      gateway = runtime['gateway']
      if route.via
        gateway && IPAddress.parse(gateway).to_s == route.via.to_s
      else
        gateway.nil?
      end
    rescue ArgumentError
      false
    end

    def runtime_route_destination_matches?(runtime, route)
      destination = runtime['dst'] || 'default'
      return false if destination == 'default'

      normalized_destination = IPAddress.parse(destination).to_string
      normalized_destination == route.addr.to_string
    rescue ArgumentError
      false
    end

    def validate_runtime_route_claim!(route, destination_routes)
      foreign = destination_routes.reject do |entry|
        runtime_route_owned?(entry) || legacy_route?(entry)
      end
      legacy = destination_routes.select { |entry| legacy_route?(entry) }
      legacy_conflicts = destination_routes.select do |entry|
        legacy_route?(entry) && !runtime_route_matches?(entry, route)
      end
      owned_destination = destination_routes.any? do |entry|
        runtime_route_owned?(entry)
      end
      legacy_ownership_ambiguous = !legacy.empty? && owned_destination
      unless foreign.empty? \
          && legacy_conflicts.empty? \
          && !legacy_ownership_ambiguous
        raise "route #{route.addr} on #{veth} conflicts with unowned state"
      end
    end

    def claim_runtime_route(version, route, destination_routes)
      legacy_match = destination_routes.any? do |entry|
        legacy_route?(entry) && runtime_route_matches?(entry, route)
      end
      owned_destination = destination_routes.any? do |entry|
        runtime_route_owned?(entry)
      end
      action = legacy_match || owned_destination ? :replace : :add
      ip(version, [:route, action] + owned_route_spec(route))
    end

    def runtime_route_owned?(runtime)
      [ROUTE_PROTOCOL_NAME, ROUTE_PROTOCOL.to_s].include?(
        runtime['protocol'].to_s
      )
    end

    def legacy_route?(runtime)
      protocol = runtime['protocol']
      protocol.nil? || protocol.to_s == 'boot'
    end

    def owned_route_spec(route)
      route.ip_spec + [:protocol, ROUTE_PROTOCOL_NAME, :dev, veth]
    end

    def runtime_route_spec(runtime)
      spec = [runtime.fetch('dst')]
      spec.push(:via, runtime.fetch('gateway'), :onlink) if runtime['gateway']
      spec.push(:protocol, ROUTE_PROTOCOL_NAME, :dev, veth)
    end

    def get_ipv6_link_local
      link = exclusively { veth.clone }

      local_ifaddr = Socket.getifaddrs.detect do |ifaddr|
        ifaddr.name == link && ifaddr.addr.ip? && ifaddr.addr.ipv6?
      end

      raise "unable to find link-local IPv6 address for #{veth}" unless local_ifaddr

      IPAddress.parse(local_ifaddr.addr.ip_address.split('%').first)
    end
  end
end
