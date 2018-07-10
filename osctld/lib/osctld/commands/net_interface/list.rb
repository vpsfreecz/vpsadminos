require 'osctld/commands/base'

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

            v = case f
                when :via
                  Hash[netif.send(f).map do |ip_v, via|
                    [ip_v, via.net_addr.to_string]
                  end]
                else
                  netif.send(f)
                end

            [f, v]
          end].merge(
            pool: ct.pool.name,
            ctid: ct.id,
          )
        end.compact
      end
    end
  end
end
