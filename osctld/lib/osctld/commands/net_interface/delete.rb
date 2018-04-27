module OsCtld
  class Commands::NetInterface::Delete < Commands::Logged
    handle :netif_delete

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ret = ct.exclusively do
        if ct.state != :stopped
          next error('the container must be stopped to remove network interface')
        end

        netif = ct.netifs.detect { |n| n.name == opts[:name] }
        next error('network interface not found') unless netif

        ct.del_netif(netif)
        ct.configure_network
        DistConfig.run(ct, :remove_netif, netif: netif)
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
