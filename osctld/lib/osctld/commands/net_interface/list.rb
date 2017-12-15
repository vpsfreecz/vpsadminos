module OsCtld
  class Commands::NetInterface::List < Commands::Base
    handle :netif_list

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      ct.inclusively do
        ok(ct.netifs.map do |netif|
          {
            name: netif.name,
            index: netif.index,
            type: netif.type,
          }
        end)
      end
    end
  end
end
