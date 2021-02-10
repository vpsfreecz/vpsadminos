require 'osctld/commands/logged'

module OsCtld
  class Commands::NetInterface::Rename < Commands::Logged
    handle :netif_rename

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        if ct.state != :stopped
          next error('the container must be stopped to rename network interface')
        end

        netif = ct.netifs[opts[:old_name]]
        next error('network interface not found') unless netif
        next ok if netif.name == opts[:new_name]

        orig_name = netif.name
        netif.rename(opts[:new_name])

        ct.save_config
        ct.lxc_config.configure_network

        DistConfig.run(
          ct.get_run_conf,
          :rename_netif,
          netif: netif,
          original_name: orig_name,
        )

        ok
      end
    end
  end
end
