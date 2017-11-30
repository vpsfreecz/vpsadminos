module OsCtld
  class Commands::User::Unregister < Commands::Base
    handle :user_unregister

    def execute
      if opts[:all]
        UserList.get do |users|
          users.each do |u|
            next unless u.registered?
            u.unregister
          end
        end

      else
        UserList.sync do
          u = UserList.find(opts[:name])
          return error('user not found') unless u
          return error('not registered') unless u.registered?
          u.unregister
        end
      end

      ok
    end
  end
end
