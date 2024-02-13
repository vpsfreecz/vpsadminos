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
          if netif.has_gateway?(ip_v)
            n.routes << Route.new(ip_v, '0.0.0.0', 0, netif.gateway(ip_v))
          end

        when :routed
          begin
            via = netif.default_via(ip_v).to_s
            n.routes << Route.new(ip_v, via, ip_v == 4 ? 32 : 128, nil)
            n.routes << Route.new(ip_v, '0.0.0.0', 0, via)
          rescue RuntimeError
            # IPv6 is routed via link-local address on the host interface, which
            # is not known when the container is stopped.
            next if ip_v == 6
          end
        end
      end

      netifs << n
    end

    # Apply configuration using netlink
    def setup
      nl = Linux::Netlink::Route::Socket.new

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

    def export
      netifs.map do |netif|
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
  end
end
