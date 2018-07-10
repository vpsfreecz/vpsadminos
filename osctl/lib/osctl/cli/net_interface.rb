require 'ipaddress'
require 'osctl/cli/command'

module OsCtl::Cli
  class NetInterface < Command
    FIELDS = %i(
      pool
      ctid
      name
      index
      type
      link
      veth
      via
      hwaddr
    )

    FILTERS = %i(
      type
      link
    )

    DEFAULT_FIELDS = %i(
      name
      type
      link
      veth
    )

    IP_FIELDS = %i(
      version
      addr
    )

    ROUTE_FIELDS = %i(
      version
      addr
    )

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      cmd_opts = {pool: gopts[:pool]}
      fmt_opts = {layout: :columns}

      cmd_opts[:id] = args[0] if args[0]

      FILTERS.each do |v|
        next unless opts[v]
        cmd_opts[v] = opts[v].split(',')
      end

      cmd_opts[:ids] = args if args.count > 0
      fmt_opts[:header] = false if opts['hide-header']

      if opts[:output]
        cols = opts[:output].split(',').map(&:to_sym)

      elsif opts[:id]
        cols = DEFAULT_FIELDS

      else
        cols = %i(pool ctid) + DEFAULT_FIELDS
      end

      osctld_fmt(:netif_list, cmd_opts, cols, fmt_opts)
    end

    def create_bridge
      require_args!('id', 'name')

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        type: 'bridge',
        hwaddr: opts[:hwaddr],
        link: opts[:link]
      }

      osctld_fmt(:netif_create, cmd_opts)
    end

    def create_routed
      require_args!('id', 'name')

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        type: 'routed',
        hwaddr: opts[:hwaddr],
        via: parse_route_via
      }

      osctld_fmt(:netif_create, cmd_opts)
    end

    def delete
      require_args!('id', 'name')
      osctld_fmt(:netif_delete, id: args[0], pool: gopts[:pool], name: args[1])
    end

    def rename
      require_args!('id', 'old-name', 'new-name')
      osctld_fmt(
        :netif_rename,
        id: args[0],
        pool: gopts[:pool],
        old_name: args[1],
        new_name: args[2]
      )
    end

    def set
      require_args!('id', 'name')

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
      }

      cmd_opts[:hwaddr] = (opts[:hwaddr] == '-' ? nil : opts[:hwaddr]) if opts[:hwaddr]
      cmd_opts[:link] = opts[:link] if opts[:link]
      cmd_opts[:via] = parse_route_via if opts[:via].any?

      osctld_fmt(:netif_set, cmd_opts)
    end

    def ip_list
      require_args!('id', 'name')

      if opts[:list]
        puts IP_FIELDS.join("\n")
        return
      end

      cmd_opts = {id: args[0], pool: gopts[:pool], name: args[1]}
      fmt_opts = {layout: :columns}

      fmt_opts[:header] = false if opts['hide-header']

      ret = []
      data = osctld_call(:netif_ip_list, cmd_opts)

      data.each do |v, addrs|
        ip_v = v.to_s.to_i
        next if opts[:version] && opts[:version] != ip_v

        addrs.each do |addr|
          ret << {
            version: ip_v,
            addr: addr,
          }
        end
      end

      format_output(
        ret,
        opts[:output] ? opts[:output].split(',').map(&:to_sym) : IP_FIELDS,
        fmt_opts
      )
    end

    def ip_add
      require_args!('id', 'name', 'addr')

      osctld_fmt(
        :netif_ip_add,
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        addr: args[2],
        route: opts['route-as'] || opts[:route],
      )
    end

    def ip_del
      require_args!('id', 'name', 'addr')

      osctld_fmt(
        :netif_ip_del,
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        addr: args[2],
        keep_route: opts['keep-route'],
      )
    end

    def route_list
      require_args!('id', 'name')

      if opts[:list]
        puts ROUTE_FIELDS.join("\n")
        return
      end

      cmd_opts = {id: args[0], pool: gopts[:pool], name: args[1]}
      fmt_opts = {layout: :columns}

      fmt_opts[:header] = false if opts['hide-header']

      ret = []
      data = osctld_call(:netif_route_list, cmd_opts)

      data.each do |v, addrs|
        ip_v = v.to_s.to_i
        next if opts[:version] && opts[:version] != ip_v

        addrs.each do |addr|
          ret << {
            version: ip_v,
            addr: addr,
          }
        end
      end

      format_output(
        ret,
        opts[:output] ? opts[:output].split(',').map(&:to_sym) : IP_FIELDS,
        fmt_opts
      )
    end

    def route_add
      require_args!('id', 'name', 'addr')

      osctld_fmt(
        :netif_route_add,
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        addr: args[2]
      )
    end

    def route_del
      require_args!('id', 'name', 'addr')

      osctld_fmt(
        :netif_route_del,
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        addr: args[2]
      )
    end

    protected
    def parse_route_via
      ret = {}

      host_addrs = opts['host-addr'].map { |v| IPAddress.parse(v) }
      ct_addrs = opts['ct-addr'].map { |v| IPAddress.parse(v) }

      opts[:via].each do |addr|
        network = IPAddress.parse(addr)
        ip_v = network.ipv4? ? 4 : 6

        if ret.has_key?(ip_v)
          raise GLI::BadCommandLine, "network for IPv#{ip_v} has already been "+
                                     "set to route via #{ret[ip_v]}"
        end

        case ip_v
        when 4
          if network.prefix > 30
            raise GLI::BadCommandLine, 'cannot route via IPv4 network smaller than /30'
          end

        when 6
          if network.prefix > 126
            raise GLI::BadCommandLine, 'cannot route via IPv6 network smaller than /126'
          end
        end

        host_addr = get_net_addr(network, host_addrs, 'host')
        ct_addr = get_net_addr(network, ct_addrs, 'container')

        if (host_addr && !ct_addr) || (!host_addr && ct_addr)
          raise GLI::BadCommandLine, 'provide both host and container address'

        elsif host_addr && host_addr == ct_addr
          raise GLI::BadCommandLine, 'use different addresses for host and container'
        end

        ret[ip_v] = {
          network: network.to_string,
          host_addr: host_addr,
          ct_addr: ct_addr,
        }
      end

      ret
    end

    def get_net_addr(network, list, type)
      addr = list.detect { |v| v.class == network.class }
      return addr if addr.nil? || network.include?(addr)

      raise GLI::BadCommandLine, "network #{network.to_string} does not "+
                                 "include #{type} address #{addr.to_string}"
    end
  end
end
