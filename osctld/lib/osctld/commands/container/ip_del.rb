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
        Routing::Router.del_ip(ct, addr) if ct.state == :running
        # TODO: remove the IP from the container if it is running
        ok
      end
    end
  end
end
