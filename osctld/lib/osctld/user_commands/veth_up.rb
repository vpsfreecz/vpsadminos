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
      ok
    end
  end
end
