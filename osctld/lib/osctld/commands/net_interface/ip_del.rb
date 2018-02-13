module OsCtld
  class Commands::NetInterface::IpDel < Commands::Logged
    handle :netif_ip_del

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
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
