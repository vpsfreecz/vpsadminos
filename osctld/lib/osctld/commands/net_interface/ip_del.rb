module OsCtld
  class Commands::NetInterface::IpDel < Commands::Base
    handle :netif_ip_del

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      netif = ct.netifs.detect { |n| n.name == opts[:name] }
      return error('network interface not found') unless netif

      addr = IPAddress.parse(opts[:addr])
      ip_v = addr.ipv4? ? 4 : 6

      ct.exclusively do
        next error('address not found') unless netif.has_ip?(addr)
        netif.del_ip(addr)
        ct.save_config
        ct.configure_network

        DistConfig.run(ct, :network)

        ok
      end
    end
  end
end
