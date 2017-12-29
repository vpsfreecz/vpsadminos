module OsCtld
  class UserCommands::CtStart < UserCommands::Base
    handle :ct_start

    include Utils::Log

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      # Configure CGroups
      ret = call_cmd(Commands::Container::CGParamApply, id: ct.id)
      return ret unless ret[:status]

      # Configure network within the CT
      DistConfig.run(ct, :network)

      ok
    end
  end
end
