require 'ipaddress'
require 'osctld/commands/logged'

module OsCtld
  class Commands::NetInterface::Set < Commands::Logged
    handle :netif_set

    UNCHANGEABLE_AT_RUNTIME = %i(hwaddr link dhcp gateways)

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)

      manipulate(ct) do
        if ct.state != :stopped
          opts.each_key do |k|
            if UNCHANGEABLE_AT_RUNTIME.include?(k)
              error!('the container must be stopped to change network interface')
            end
          end
        end

        netif = ct.netifs[opts[:name]]
        netif || error!('network interface not found')

        change_opts = generic_opts
        change_opts.update(send("#{netif.type}_opts", netif))

        netif.set(change_opts)

        ct.save_config
        ct.lxc_config.configure_network

        ok
      end
    end

    protected
    def bridge_opts(netif)
      ret = {link: opts[:link]}
      ret[:dhcp] = opts[:dhcp] if opts.has_key?(:dhcp)

      if opts[:gateways]
        ret[:gateways] = Hash[ opts[:gateways].map { |k,v| [k.to_s.to_i, v] } ]
      end

      ret
    end

    def routed_opts(netif)
      {}
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

      %i(tx_queues rx_queues).each do |v|
        next unless opts[v]

        if !opts[v].is_a?(Integer) || opts[v] < 1
          error!("#{v} must be a number greater or equal to 1")
        end

        ret[v] = opts[v]
      end

      %i(max_tx max_rx).each do |v|
        next unless opts[v]

        if !opts[v].is_a?(Integer) || opts[v] < 0
          error!("#{v} must be a number greater or equal to zero")
        end

        ret[v] = opts[v]
      end

      ret
    end
  end
end
