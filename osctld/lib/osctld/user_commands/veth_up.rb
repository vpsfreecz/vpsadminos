module OsCtld
  class UserCommands::VethUp < UserCommands::Base
    handle :veth_up

    include Utils::Log

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      log(
        :info,
        "CT #{ct.id}",
        "veth interface coming up: index=#{opts[:index]}, name=#{opts[:veth]}"
      )
      ct.netif_at(opts[:index]).up(opts[:veth])
      ok
    end
  end
end
