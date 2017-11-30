module OsCtld
  class Commands::Container::Su < Commands::Base
    handle :ct_su

    include Utils::Log
    include Utils::SwitchUser

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      ok(cmd: user_exec(ct.user, '/bin/bash'))
    end
  end
end
