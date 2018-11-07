require 'osctld/commands/base'

module OsCtld
  class Commands::NetInterface::IpList < Commands::Base
    handle :netif_ip_list

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
            netif = ct.netifs[opts[:name]]
            netif || error!('network interface not found')

            ret << [ct, netif]

          else
            ct.netifs.each { |netif| ret << [ct, netif] }
          end
        end

      elsif opts[:pool]
        DB::Container.get.each do |ct|
          next if ct.pool.name != opts[:pool]

          ct.inclusively do
            ct.netifs.each { |netif| ret << [ct, netif] }
          end
        end

      else
        DB::Containers.get.map do |ct|
          ct.inclusively do
            ct.netifs.each { |netif| ret << [ct, netif] }
          end
        end
      end

      ret
    end

    def add_netif(ct, netif)
      {
        :pool => ct.pool.name,
        :ctid => ct.id,
        :netif => netif.name,
        4 => netif.ips(4).map(&:to_string),
        6 => netif.ips(6).map(&:to_string),
      }
    end
  end
end
