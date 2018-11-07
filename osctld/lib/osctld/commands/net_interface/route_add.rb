require 'osctld/commands/logged'
require 'ipaddress'

module OsCtld
  class Commands::NetInterface::RouteAdd < Commands::Logged
    handle :netif_route_add

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      netif = ct.netifs[opts[:name]]
      netif || error!('network interface not found')
      netif.type == :routed || error!('not a routed interface')

      addr = IPAddress.parse(opts[:addr])
      ip_v = addr.ipv4? ? 4 : 6

      manipulate(ct) do
        # TODO: check that no other container routes this IP
        error!('this address is already routed') if netif.routes.route?(addr)

        netif.add_route(addr)
        ct.save_config
        ct.lxc_config.configure_network

        DistConfig.run(ct, :network) if ct.can_dist_configure_network?

        ok
      end
    end
  end
end
