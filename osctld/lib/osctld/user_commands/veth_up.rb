module OsCtld
  class UserCommands::VethUp < UserCommands::Base
    handle :veth_up

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)
      ok
    end
  end
end
