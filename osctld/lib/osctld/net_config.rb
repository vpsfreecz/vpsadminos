require 'linux/netlink/route'
require 'linux/netlink/route/addr_handler'
require 'linux/netlink/route/link_handler'
require 'linux/netlink/route/route_handler'

module OsCtld
  # Generate network configuration for a container and apply using netlink
  #
  # {NetConfig} has to be created before switching to container user and
  # attaching to the container. Call {.create} while running as root and
  # {#setup} while attached into a container.
  class NetConfig
    NetIf = Struct.new(:name, :ips, :routes)
    Addr = Struct.new(:version, :address, :prefix)
    Route = Struct.new(:version, :address, :prefix, :via)

    attr_reader :netifs

    # @param ct [Container]
    def self.create(ct)
      cfg = new
      ct.netifs.each { |netif| cfg.add_netif(netif) }
      cfg
    end

    def self.setup_in_netns(init_identity, net_config)
      sys = OsCtl::Lib::Sys.new
      sys.setns_io(init_identity.namespace(:net), OsCtl::Lib::Sys::CLONE_NEWNET)
      import(net_config).setup
    end

    def self.import(data)
      cfg = new
      cfg.import(data)
      cfg
    end

    def initialize
      @netifs = []
    end

    # @param netif [NetInterface::Base]
    def add_netif(netif)
      n = NetIf.new(netif.name, [], [])

      [4, 6].each do |ip_v|
        if netif.respond_to?(:ips)
          netif.ips(ip_v).each do |ip|
            n.ips << Addr.new(ip_v, ip.to_s, ip.prefix.to_i)
          end
        end

        case netif.type
        when :bridge
          next unless static_bridge?(netif)

          gateway = static_bridge_gateway(netif, ip_v)
          if gateway
            n.routes << Route.new(ip_v, default_route_addr(ip_v), 0, gateway)
          end

        when :routed
          begin
            via = netif.default_via(ip_v).to_s
            n.routes << Route.new(ip_v, via, ip_v == 4 ? 32 : 128, nil)
            n.routes << Route.new(ip_v, default_route_addr(ip_v), 0, via)
          rescue RuntimeError
            # IPv6 is routed via link-local address on the host interface, which
            # is not known when the container is stopped.
            next if ip_v == 6
          end
        end
      end

      netifs << n
    end

    def empty?
      netifs.all? { |netif| empty_netif?(netif) }
    end

    # Apply configuration using netlink
    def setup
      nl = Linux::Netlink::Route::Socket.new
      wait_for_netifs(nl)

      netifs.each do |netif|
        netif.ips.each do |ip|
          nl.addr.add(index: netif.name, local: ip.address, prefixlen: ip.prefix)
        rescue Errno::EEXIST
          next
        end

        netif.routes.each do |route|
          nl.route.add(
            oif: netif.name,
            dst: route.address,
            dst_len: route.prefix,
            gateway: route.via
          )
        rescue Errno::EEXIST
          next
        end
      end
    end

    def export(configured_only: false)
      exported_netifs =
        if configured_only
          netifs.reject { |netif| empty_netif?(netif) }
        else
          netifs
        end

      exported_netifs.map do |netif|
        {
          name: netif.name,
          ips: netif.ips.map(&:to_h),
          routes: netif.routes.map(&:to_h)
        }
      end
    end

    def import(data)
      data.each do |netif_hash|
        netifs << NetIf.new(
          netif_hash[:name],
          netif_hash[:ips].map do |v|
            Addr.new(v[:version], v[:address], v[:prefix])
          end,
          netif_hash[:routes].map do |v|
            Route.new(v[:version], v[:address], v[:prefix], v[:via])
          end
        )
      end
    end

    protected

    def wait_for_netifs(nl, timeout: 10)
      names = netifs.map(&:name).uniq
      return if names.empty?

      deadline = Time.now + timeout
      missing = []

      loop do
        existing = nl.link.list.map(&:ifname)
        missing = names - existing
        return if missing.empty?
        break if Time.now >= deadline

        sleep(0.1)
      end

      raise "network interfaces not found: #{missing.join(', ')}"
    end

    def default_route_addr(ip_v)
      ip_v == 4 ? '0.0.0.0' : '::'
    end

    def static_bridge?(netif)
      !netif.respond_to?(:dhcp) || !netif.dhcp
    end

    def static_bridge_gateway(netif, ip_v)
      if netif.respond_to?(:gateway_or_nil)
        netif.gateway_or_nil(ip_v, wait: true)
      elsif netif.has_gateway?(ip_v)
        netif.gateway(ip_v)
      end
    end

    def empty_netif?(netif)
      netif.ips.empty? && netif.routes.empty?
    end
  end
end
