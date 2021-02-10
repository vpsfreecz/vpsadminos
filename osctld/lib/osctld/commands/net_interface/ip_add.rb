require 'osctld/commands/logged'
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
      netif = ct.netifs[opts[:name]]
      return error('network interface not found') unless netif

      addr = IPAddress.parse(opts[:addr])
      ip_v = addr.ipv4? ? 4 : 6

      manipulate(ct) do
        # TODO: check that no other container has this IP
        next error('this address is already assigned') if netif.has_ip?(addr)

        case netif.type
        when :routed
          netif.add_ip(addr, route(netif, addr))
        else
          netif.add_ip(addr)
        end

        ct.save_config
        ct.lxc_config.configure_network

        DistConfig.run(ct.get_run_conf, :network) if ct.can_dist_configure_network?

        ok
      end
    end

    protected
    def route(netif, addr)
      if opts[:route] === true
        addr.network

      elsif opts[:route]
        ret = IPAddress.parse(opts[:route])

        if ret.class != addr.class
          error!('IP version mismatch')

        elsif !ret.include?(addr)
          error!("#{ret.to_string} does not include #{addr.to_string}")
        end

        ret

      else
        nil
      end
    end
  end
end
