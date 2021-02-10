require 'osctld/commands/logged'

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
      netif = ct.netifs[opts[:name]]
      return error('network interface not found') unless netif

      manipulate(ct) do
        if opts[:addr] == 'all'
          v = opts[:version] && opts[:version].to_i

          case netif.type
          when :routed
            netif.del_all_ips(v, opts[:keep_route])
          else
            netif.del_all_ips(v)
          end

        else
          addr = IPAddress.parse(opts[:addr])
          ip_v = addr.ipv4? ? 4 : 6

          error!('address not found') unless netif.has_ip?(addr)

          case netif.type
          when :routed
            netif.del_ip(addr, opts[:keep_route])
          else
            netif.del_ip(addr)
          end
        end

        ct.save_config
        ct.lxc_config.configure_network

        DistConfig.run(ct.get_run_conf, :network) if ct.can_dist_configure_network?
      end

      ok
    end
  end
end
