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
      dhcp
      veth
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
      pool
      ctid
      netif
      version
      addr
    )

    ROUTE_FIELDS = %i(
      pool
      ctid
      netif
      version
      addr
    )

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      cmd_opts = {pool: gopts[:pool]}
      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
      }

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
        link: opts[:link],
        dhcp: opts[:dhcp],
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

      if opts['enable-dhcp']
        cmd_opts[:dhcp] = true
      elsif opts['disable-dhcp']
        cmd_opts[:dhcp] = false
      end

      osctld_fmt(:netif_set, cmd_opts)
    end

    def ip_list
      if opts[:list]
        puts IP_FIELDS.join("\n")
        return
      end

      cmd_opts = {pool: gopts[:pool]}
      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
      }

      cmd_opts[:id] = args[0] if args[0]
      cmd_opts[:name] = args[1] if args[1]

      fmt_opts[:header] = false if opts['hide-header']

      ret = []
      data = osctld_call(:netif_ip_list, cmd_opts)

      data.each do |netif|
        [4, 6].each do |ip_v|
          next if opts[:version] && opts[:version] != ip_v

          netif[ip_v.to_s.to_sym].each do |addr|
            ret << {
              pool: netif[:pool],
              ctid: netif[:ctid],
              netif: netif[:netif],
              version: ip_v,
              addr: addr,
            }
          end
        end
      end

      if opts[:output]
        cols = opts[:output].split(',').map(&:to_sym)

      elsif args.count >= 2
        cols = %i(version addr)

      elsif args.count >= 1
        cols = %i(netif version addr)

      else
        cols = IP_FIELDS
      end

      format_output(ret, cols, fmt_opts)
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
        version: opts[:version],
      )
    end

    def route_list
      if opts[:list]
        puts ROUTE_FIELDS.join("\n")
        return
      end

      cmd_opts = {pool: gopts[:pool]}
      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
      }

      cmd_opts[:id] = args[0] if args[0]
      cmd_opts[:name] = args[1] if args[1]

      fmt_opts[:header] = false if opts['hide-header']

      ret = []
      data = osctld_call(:netif_route_list, cmd_opts)

      data.each do |netif|
        [4, 6].each do |ip_v|
          next if opts[:version] && opts[:version] != ip_v

          netif[ip_v.to_s.to_sym].each do |addr|
            ret << {
              pool: netif[:pool],
              ctid: netif[:ctid],
              netif: netif[:netif],
              version: ip_v,
              addr: addr,
            }
          end
        end
      end

      if opts[:output]
        cols = opts[:output].split(',').map(&:to_sym)

      elsif args.count >= 2
        cols = %i(version addr)

      elsif args.count >= 1
        cols = %i(netif version addr)

      else
        cols = ROUTE_FIELDS
      end

      format_output(ret, cols, fmt_opts)
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
        addr: args[2],
        version: opts[:version],
      )
    end
  end
end
