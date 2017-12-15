module OsCtld
  class Commands::NetInterface::IpList < Commands::Base
    handle :netif_ip_list

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      netif = ct.netifs.detect { |n| n.name == opts[:name] }
      return error('network interface not found') unless netif

      ok(4 => netif.ips(4).map(&:to_string), 6 => netif.ips(6).map(&:to_string))
    end
  end
end
