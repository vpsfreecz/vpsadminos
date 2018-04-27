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

      ret = ct.exclusively do
        if ct.state != :stopped
          next error('the container must be stopped to add network interface')

        elsif ct.netifs.detect { |v| v.name == opts[:name] }
          next error("interface '#{opts[:name]}' already exists")
        end

        netif = klass.new(ct, ct.netifs.count)

        if opts[:via]
          opts[:via] = Hash[ opts[:via].map { |k,v| [k.to_s.to_i, v] } ]
        end

        netif.create(opts)
        netif.setup

        ct.add_netif(netif)
        ct.configure_network
        DistConfig.run(ct, :add_netif, netif: netif)
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
