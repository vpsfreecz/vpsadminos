require 'osctld/commands/logged'

module OsCtld
  class Commands::NetInterface::Create < Commands::Logged
    handle :netif_create

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      klass = NetInterface.for(opts[:type].to_sym)
      return error("'#{opts[:type]}' is not supported") unless klass

      ret = manipulate(ct) do
        if ct.state != :stopped
          next error('the container must be stopped to add network interface')

        elsif ct.netifs.contains?(opts[:name])
          next error("interface '#{opts[:name]}' already exists")
        end

        netif = klass.new(ct, ct.netifs.count)
        netif.create(opts)
        netif.setup

        ct.netifs << netif
        ct.lxc_config.configure_network
        DistConfig.run(ct.get_run_conf, :add_netif, netif: netif)
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
