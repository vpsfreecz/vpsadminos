module OsCtld
  class Commands::User::Su < Commands::Base
    handle :user_su

    include Utils::Log
    include Utils::SwitchUser

    def execute
      u = UserList.find(opts[:name])
      return error('user not found') unless u

      ok(cmd: user_exec(u, '/bin/bash'))
    end
  end
end
