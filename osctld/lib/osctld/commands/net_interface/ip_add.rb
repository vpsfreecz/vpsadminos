require 'ipaddress'

module OsCtld
  class Commands::NetInterface::IpAdd < Commands::Logged
    handle :netif_ip_add

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
        # TODO: check that no other container has this IP
        next error('this address is already assigned') if netif.has_ip?(addr)

        unless netif.can_add_ip?(addr)
          next error("network interface not configured for IPv#{ip_v}")
        end

        netif.add_ip(addr)
        ct.save_config
        ct.configure_network

        DistConfig.run(ct, :network)

        ok
      end
    end
  end
end
