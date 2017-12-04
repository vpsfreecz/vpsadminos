module OsCtld
  class UserCommands::VethUp < UserCommands::Base
    handle :veth_up

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      if ct.veth
        raise "Container #{ct.id} already has veth interface #{ct.veth}, "+
              "unable to assign veth #{opts[:veth]}. Only one veth interface "+
              "per container is supported."
      end

      ct.veth = opts[:veth]

      [4, 6].each do |v|
        ips = ct.ips(v)
        next if ips.empty?

        ips.each do |ip|
          Routing::Router.add_ip(ct, IPAddress.parse(ip))
        end
      end

      ok
    end
  end
end
