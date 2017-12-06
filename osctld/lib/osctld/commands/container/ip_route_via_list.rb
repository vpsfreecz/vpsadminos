module OsCtld
  class Commands::Container::IpRouteViaList < Commands::Base
    handle :ct_ip_route_via_list

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      ok(4 => ct.route_via(4), 6 => ct.route_via(6))
    end
  end
end
