module OsCtld
  class Commands::NetInterface::Show < Commands::Base
    handle :netif_show

    FIELDS = %i(
      name
      index
      type
      link
      veth
      via
    )

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        netif = ct.netifs.detect { |v| v.name == opts[:name] }
        next error('interface not found') unless netif

        ok(
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
        )
      end
    end
  end
end
