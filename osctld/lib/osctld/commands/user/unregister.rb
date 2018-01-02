module OsCtld
  class Commands::User::Unregister < Commands::Base
    handle :user_unregister

    def execute
      if opts[:all]
        DB::Users.get do |users|
          users.each do |u|
            next unless u.registered?
            u.unregister
          end
        end

      else
        DB::Users.sync do
          u = DB::Users.find(opts[:name])
          return error('user not found') unless u
          return error('not registered') unless u.registered?
          u.unregister
        end
      end

      ok
    end
  end
end
