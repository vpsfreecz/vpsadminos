module OsCtld
  class Commands::NetInterface::Delete < Commands::Base
    handle :netif_delete

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      ret = ct.exclusively do
        if ct.state != :stopped
          next error('the container must be stopped to remove network interface')
        end

        netif = ct.netifs.detect { |n| n.name == opts[:name] }
        next error('network interface not found') unless netif

        ct.del_netif(netif)
        ct.configure_network
        ok
      end

      if ret[:status]
        call_cmd(Commands::User::LxcUsernet)
        ok

      else
        ret
      end
    end
  end
end
