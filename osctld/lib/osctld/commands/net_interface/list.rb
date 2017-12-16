module OsCtld
  class Commands::NetInterface::List < Commands::Base
    handle :netif_list

    FIELDS = %i(
      name
      index
      type
      link
      veth
      via
    )

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      ct.inclusively do
        ok(ct.netifs.map do |netif|
          next if opts[:type] && !opts[:type].include?(netif.type.to_s)
          next if opts[:link] && (netif.type != :bridge || !opts[:link].include?(netif.link))

          Hash[FIELDS.map do |f|
            next [f, nil] unless netif.respond_to?(f)

            v = case f
                when :via
                  Hash[netif.send(f).map do |ip_v, via|
                    [ip_v, via.net_addr.to_string]
                  end]
                else
                  netif.send(f)
                end

            [f, v]
          end]
        end.compact)
      end
    end
  end
end
