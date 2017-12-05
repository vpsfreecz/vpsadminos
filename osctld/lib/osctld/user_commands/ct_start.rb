module OsCtld
  class UserCommands::CtStart < UserCommands::Base
    handle :ct_start

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      Script::Container::Network.run(ct)

      ok
    end
  end
end
