module OsCtld
  class Commands::Container::IpDel < Commands::Base
    handle :ct_ip_del

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct
      addr = IPAddress.parse(opts[:addr])

      ct.exclusively do
        next error('address not found') unless ct.has_ip?(addr)
        ct.del_ip(addr)
        Script::Container::Network.run(ct)

        if ct.state == :running
          Routing::Router.del_ip(ct, addr)
          ct_syscmd(ct, "ip addr del #{addr.to_string} dev eth0", valid_rcs: [2])
        end

        ok
      end
    end
  end
end
