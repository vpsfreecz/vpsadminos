module OsCtld
  class Commands::User::Register < Commands::Base
    handle :user_register

    def execute
      if opts[:all]
        UserList.get do |users|
          users.each do |u|
            next if u.registered?
            u.register
          end
        end

      else
        UserList.sync do
          u = UserList.find(opts[:name])
          return error('user not found') unless u
          return error('already registered') if u.registered?
          u.register
        end
      end

      ok
    end
  end
end
