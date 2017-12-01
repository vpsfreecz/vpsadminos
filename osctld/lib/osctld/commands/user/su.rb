module OsCtld
  class Commands::User::Su < Commands::Base
    handle :user_su

    include Utils::Log
    include Utils::SwitchUser

    def execute
      u = UserList.find(opts[:name])
      return error('user not found') unless u

      ok(user_exec(u, 'bash'))
    end
  end
end
