require 'osctld/commands/base'

module OsCtld
  class Commands::User::Register < Commands::Base
    handle :user_register

    def execute
      if opts[:all]
        DB::Users.get do |users|
          users.each do |u|
            next if opts[:pool] && u.pool.name != opts[:pool]
            next if u.registered?

            begin
              register_user(u)
            rescue ResourceLocked => e
              progress("User #{u.ident} is locked, skipping")
            end
          end
        end

      else
        DB::Users.sync do
          u = DB::Users.find(opts[:name], opts[:pool])
          return error('user not found') unless u
          return error('already registered') if u.registered?

          register_user(u)
        end
      end

      ok
    end

    protected

    def register_user(u)
      manipulate(u) do
        progress("Registering user #{u.ident}")
        SystemUsers.add(u.sysusername, u.ugid, u.homedir)
        u.registered = true
      end
    end
  end
end
