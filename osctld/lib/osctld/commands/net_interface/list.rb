require 'osctld/commands/base'

module OsCtld
  class Commands::NetInterface::List < Commands::Base
    handle :netif_list

    FIELDS = %i(
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

    def execute
      ret = []

      cts.each do |ct|
        ret.concat(add_ct(ct))
      end

      ok(ret)
    end

    protected
    def cts
      if opts[:id]
        ct = DB::Containers.find(opts[:id], opts[:pool])
        ct || error!('container not found')
        [ct]

      elsif opts[:pool]
        DB::Container.get.select { |ct| ct.pool.name == opts[:pool] }

      else
        DB::Containers.get
      end
    end

    def add_ct(ct)
      ct.inclusively do
        ct.netifs.map do |netif|
          next if opts[:type] && !opts[:type].include?(netif.type.to_s)
          next if opts[:link] && (netif.type != :bridge || !opts[:link].include?(netif.link))

          Hash[FIELDS.map do |f|
            next [f, nil] unless netif.respond_to?(f)
            [f, netif.send(f)]
          end].merge(
            pool: ct.pool.name,
            ctid: ct.id,
          )
        end.compact
      end
    end
  end
end
