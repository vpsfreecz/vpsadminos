require 'osctld/commands/base'

module OsCtld
  class Commands::NetInterface::RouteList < Commands::Base
    handle :netif_route_list

    def execute
      ok(netifs.map do |ct, netif|
        add_netif(ct, netif)
      end)
    end

    protected
    def netifs
      ret = []

      if opts[:id]
        ct = DB::Containers.find(opts[:id], opts[:pool])
        ct || error!('container not found')

        ct.inclusively do
          if opts[:name]
            netif = ct.netifs.detect { |n| n.name == opts[:name] }
            netif || error!('network interface not found')
            netif.type == :routed || error!('not a routed interface')

            ret << [ct, netif]

          else
            ct.netifs.each do |netif|
              next if netif.type != :routed
              ret << [ct, netif]
            end
          end
        end

      elsif opts[:pool]
        DB::Container.get.each do |ct|
          next if ct.pool.name != opts[:pool]

          ct.inclusively do
            ct.netifs.each do |netif|
              next if netif.type != :routed
              ret << [ct, netif]
            end
          end
        end

      else
        DB::Containers.get.map do |ct|
          ct.inclusively do
            ct.netifs.each do |netif|
              next if netif.type != :routed
              ret << [ct, netif]
            end
          end
        end
      end

      ret
    end

    def add_netif(ct, netif)
      netif.routes.export.merge(
        pool: ct.pool.name,
        ctid: ct.id,
        netif: netif.name,
      )
    end
  end
end
