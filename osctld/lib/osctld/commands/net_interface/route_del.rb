require 'osctld/commands/logged'

module OsCtld
  class Commands::NetInterface::RouteDel < Commands::Logged
    handle :netif_route_del

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      netif = ct.netifs.detect { |n| n.name == opts[:name] }
      netif || error!('network interface not found')
      netif.type == :routed || error!('not a routed interface')

      ct.exclusively do
        if opts[:addr] == 'all'
          netif.del_all_routes(opts[:version] && opts[:version].to_i)

        else
          addr = IPAddress.parse(opts[:addr])
          ip_v = addr.ipv4? ? 4 : 6

          error!('route not found') unless netif.has_route?(addr)
          netif.del_route(addr)
        end

        ct.save_config
        ct.configure_network

        DistConfig.run(ct, :network)
      end

      ok
    end
  end
end
