module OsCtld
  class UserCommands::VethDown < UserCommands::Base
    handle :veth_down

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)
      ct.veth = nil
      ok
    end
  end
end
