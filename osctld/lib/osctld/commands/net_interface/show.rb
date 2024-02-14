require 'osctld/commands/base'

module OsCtld
  class Commands::NetInterface::Show < Commands::Base
    handle :netif_show

    FIELDS = %i[
      name
      index
      type
      link
      dhcp
      veth
    ]

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        netif = ct.netifs[opts[:name]]
        next error('interface not found') unless netif

        ok(
          FIELDS.to_h do |f|
            next [f, nil] unless netif.respond_to?(f)

            [f, netif.send(f)]
          end
        )
      end
    end
  end
end
