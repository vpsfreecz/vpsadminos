require 'ipaddress'

module OsCtld
  class Commands::Container::IpAdd < Commands::Base
    handle :ct_ip_add

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct
      addr = IPAddress.parse(opts[:addr])
      ip_v = addr.ipv4? ? 4 : 6

      ct.exclusively do
        # TODO: check that no other container has this IP
        next error('this address is already assigned') if ct.has_ip?(addr)

        unless ct.can_route?(ip_v)
          next error("routing not configured for IPv#{ip_v}")
        end

        ct.add_ip(addr)
        Routing::Router.add_ip(ct, addr) if ct.state == :running
        ok
      end
    end
  end
end
