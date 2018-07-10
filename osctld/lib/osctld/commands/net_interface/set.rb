require 'ipaddress'
require 'osctld/commands/logged'

module OsCtld
  class Commands::NetInterface::Set < Commands::Logged
    handle :netif_set

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        if ct.state != :stopped
          error!('the container must be stopped to change network interface')
        end

        netif = ct.netif_by(opts[:name])
        netif || error!('network interface not found')

        change_opts = generic_opts
        change_opts.update(send("#{netif.type}_opts", netif))

        netif.set(change_opts)

        ct.save_config
        ct.configure_network

        ok
      end
    end

    protected
    def bridge_opts(netif)
      {link: opts[:link]}
    end

    def routed_opts(netif)
      ret = {}
      return ret unless opts[:via]

      [4, 6].each do |ip_v|
        k = ip_v.to_s.to_sym
        next unless opts[:via][k]

        via = opts[:via][k]
        network = IPAddress.parse(via[:network])
        host_addr = via[:host_addr] && IPAddress.parse(via[:host_addr])
        ct_addr = via[:ct_addr] && IPAddress.parse(via[:ct_addr])

        case ip_v
        when 4
          if network.prefix > 30
            error!('cannot route via IPv4 network smaller than /30')
          end

        when 6
          if network.prefix > 126
            error!('cannot route via IPv6 network smaller than /126')
          end
        end

        if host_addr && !network.include?(host_addr)
          error!("network #{network.to_string} does not include host "+
                 "address #{addr.to_string}")

        elsif ct_addr && !network.include?(ct_addr)
          error!("network #{network.to_string} does not include container "+
                 "address #{addr.to_string}")

        elsif (host_addr && !ct_addr) || (!host_addr && ct_addr)
          error!('provide both host and container address')

        elsif host_addr && host_addr == ct_addr
          error!('use different addresses for host and container')
        end

        ret[ip_v] = {
          network: network,
          host_addr: host_addr,
          ct_addr: ct_addr,
        }
      end

      netif.active_ip_versions.each do |ip_v|
        next if ret[ip_v] || netif.routes.empty?(ip_v)

        error!("expected network for IPv#{ip_v}, there are routes present")
      end

      {via: ret}
    end

    def generic_opts
      ret = {}

      if opts.has_key?(:hwaddr)
        if opts[:hwaddr].is_a?(String) && opts[:hwaddr].length == 17
          ret[:hwaddr] = opts[:hwaddr]

        elsif opts[:hwaddr].nil?
          ret[:hwaddr] = nil

        else
          error!('hwaddr has to be a 17 character string or null')
        end
      end

      ret
    end
  end
end
