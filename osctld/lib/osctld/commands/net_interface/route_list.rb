require 'osctld/commands/base'

module OsCtld
  class Commands::NetInterface::RouteList < Commands::Base
    handle :netif_route_list

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')

      netif = ct.netifs.detect { |n| n.name == opts[:name] }
      netif || error!('network interface not found')

      netif.type == :routed || error!('not a routed interface')

      ok(netif.routes.export)
    end
  end
end
