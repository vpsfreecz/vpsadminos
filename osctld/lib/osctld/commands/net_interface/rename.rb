module OsCtld
  class Commands::NetInterface::Rename < Commands::Logged
    handle :netif_rename

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        if ct.state != :stopped
          next error('the container must be stopped to rename network interface')
        end

        netif = ct.netif_by(opts[:old_name])
        next error('network interface not found') unless netif
        next ok if netif.name == opts[:new_name]

        netif.rename(opts[:new_name])

        ct.save_config
        ct.configure_network

        ok
      end
    end
  end
end
