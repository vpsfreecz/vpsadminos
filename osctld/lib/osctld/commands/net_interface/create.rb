module OsCtld
  class Commands::NetInterface::Create < Commands::Base
    handle :netif_create

    def execute
      ct = DB::Containers.find(opts[:id])
      return error('container not found') unless ct

      klass = NetInterface.for(opts[:type].to_sym)
      return error("'#{opts[:type]}' is not supported") unless klass

      ret = ct.exclusively do
        if ct.state != :stopped
          next error('the container must be stopped to add network interface')
        end

        netif = klass.new(ct, ct.netifs.count)

        if opts[:via]
          opts[:via] = Hash[ opts[:via].map { |k,v| [k.to_s.to_i, v] } ]
        end

        netif.create(opts)
        netif.setup

        ct.add_netif(netif)
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
