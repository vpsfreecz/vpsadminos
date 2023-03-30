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
      gateways
      veth
      hwaddr
      tx_queues
      rx_queues
      max_tx
      max_rx
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
      max_tx
      max_rx
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
      via
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

      cols =
        if opts[:output]
          opts[:output].split(',').map(&:to_sym)
        elsif opts[:id]
          DEFAULT_FIELDS
        else
          %i(pool ctid) + DEFAULT_FIELDS
        end

      %i(max_tx max_rx).each do |limit|
        i = cols.index(limit)
        next if i.nil?

        cols[i] = {
          name: limit,
          label: limit.to_s.upcase,
          align: 'right',
          display: Proc.new do |v|
            if gopts[:parsable] \
               || gopts[:json] \
               || (!v.is_a?(Integer) && /^\d+$/ !~ v)
              v
            else
              humanize_data(v.to_i)
            end
          end
        }
      end

      fmt_opts[:cols] = cols

      osctld_fmt(:netif_list, cmd_opts: cmd_opts, fmt_opts: fmt_opts)
    end

    def create_bridge
      require_args!('id', 'name')

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        type: 'bridge',
        hwaddr: opts[:hwaddr],
        tx_queues: opts['tx-queues'],
        rx_queues: opts['rx-queues'],
        link: opts[:link],
        dhcp: opts[:dhcp],
      }

      parse_gateway(cmd_opts)
      parse_shaper(cmd_opts)

      osctld_fmt(:netif_create, cmd_opts: cmd_opts)
    end

    def create_routed
      require_args!('id', 'name')

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        type: 'routed',
        hwaddr: opts[:hwaddr],
        tx_queues: opts['tx-queues'],
        rx_queues: opts['rx-queues'],
      }

      parse_shaper(cmd_opts)

      osctld_fmt(:netif_create, cmd_opts: cmd_opts)
    end

    def delete
      require_args!('id', 'name')
      osctld_fmt(:netif_delete, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
      })
    end

    def rename
      require_args!('id', 'old-name', 'new-name')
      osctld_fmt(:netif_rename, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        old_name: args[1],
        new_name: args[2]
      })
    end

    def set
      require_args!('id', 'name')

      cmd_opts = {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
      }

      cmd_opts[:hwaddr] = (opts[:hwaddr] == '-' ? nil : opts[:hwaddr]) if opts[:hwaddr]
      cmd_opts[:tx_queues] = opts['tx-queues'] if opts['tx-queues']
      cmd_opts[:rx_queues] = opts['rx-queues'] if opts['rx-queues']
      cmd_opts[:link] = opts[:link] if opts[:link]
      parse_gateway(cmd_opts)

      if opts['enable-dhcp']
        cmd_opts[:dhcp] = true
      elsif opts['disable-dhcp']
        cmd_opts[:dhcp] = false
      end

      parse_shaper(cmd_opts)

      osctld_fmt(:netif_set, cmd_opts: cmd_opts)
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
      data = osctld_call(:netif_ip_list, **cmd_opts)

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

      fmt_opts[:cols] =
        if opts[:output]
          opts[:output].split(',').map(&:to_sym)
        elsif args.count >= 2
          %i(version addr)
        elsif args.count >= 1
          %i(netif version addr)
        else
          IP_FIELDS
        end

      format_output(ret, **fmt_opts)
    end

    def ip_add
      require_args!('id', 'name', 'addr')

      osctld_fmt(:netif_ip_add, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        addr: args[2],
        route: opts['route-as'] || opts[:route],
      })
    end

    def ip_del
      require_args!('id', 'name', 'addr')

      osctld_fmt(:netif_ip_del, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        addr: args[2],
        keep_route: opts['keep-route'],
        version: opts[:version],
      })
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
      data = osctld_call(:netif_route_list, **cmd_opts)

      data.each do |netif|
        [4, 6].each do |ip_v|
          next if opts[:version] && opts[:version] != ip_v

          netif[ip_v.to_s.to_sym].each do |addr|
            ret << {
              pool: netif[:pool],
              ctid: netif[:ctid],
              netif: netif[:netif],
              version: ip_v,
              addr: addr[:address],
              via: addr[:via],
            }
          end
        end
      end

      fmt_opts[:cols] =
        if opts[:output]
          opts[:output].split(',').map(&:to_sym)
        elsif args.count >= 2
          %i(version addr via)
        elsif args.count >= 1
          %i(netif version addr via)
        else
          cols = ROUTE_FIELDS
        end

      format_output(ret, **fmt_opts)
    end

    def route_add
      require_args!('id', 'name', 'addr')

      osctld_fmt(:netif_route_add, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        addr: args[2],
        via: opts[:via],
      })
    end

    def route_del
      require_args!('id', 'name', 'addr')

      osctld_fmt(:netif_route_del, cmd_opts: {
        id: args[0],
        pool: gopts[:pool],
        name: args[1],
        addr: args[2],
        version: opts[:version],
      })
    end

    protected
    def parse_gateway(cmd_opts)
      gws = [4, 6].map { |v| [v, "gateway-v#{v}"] }.select { |v, opt| opts[opt] }
      return if gws.empty?

      cmd_opts[:gateways] = Hash[gws.map do |v, opt|
        [v, opts[opt]]
      end]
    end

    def parse_shaper(cmd_opts)
      if opts['max-tx']
        cmd_opts[:max_tx] =
          if opts['max-tx'] == 'unlimited'
            0
          else
            parse_data(opts['max-tx'])
          end
      end

      if opts['max-rx']
        cmd_opts[:max_rx] =
          if opts['max-rx'] == 'unlimited'
            0
          else
            parse_data(opts['max-rx'])
          end
      end
    end
  end
end
