module OsCtld
  class Commands::User::Register < Commands::Base
    handle :user_register

    def execute
      if opts[:all]
        DB::Users.get do |users|
          users.each do |u|
            next if opts[:pool] && u.pool.name != opts[:pool]
            next if u.registered?
            u.register
          end
        end

      else
        DB::Users.sync do
          u = DB::Users.find(opts[:name], opts[:pool])
          return error('user not found') unless u
          return error('already registered') if u.registered?
          u.register
        end
      end

      ok
    end
  end
end
