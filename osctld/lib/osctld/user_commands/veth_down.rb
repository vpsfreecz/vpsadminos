module OsCtld
  class UserCommands::VethDown < UserCommands::Base
    handle :veth_down

    include Utils::Log

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      log(
        :info,
        "CT #{ct.id}",
        "veth interface coming down: index=#{opts[:index]}, name=#{opts[:veth]}"
      )
      ct.netif_at(opts[:index]).down(opts[:veth])
      ok
    end
  end
end
