require 'osctld/commands/logged'

module OsCtld
  class Commands::NetInterface::Delete < Commands::Logged
    handle :netif_delete

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ret = manipulate(ct) do
        if ct.state != :stopped
          next error('the container must be stopped to remove network interface')
        end

        netif = ct.netifs[opts[:name]]
        next error('network interface not found') unless netif

        ct.netifs.delete(netif)
        ct.lxc_config.configure_network
        DistConfig.run(ct.get_run_conf, :remove_netif, netif: netif)
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
