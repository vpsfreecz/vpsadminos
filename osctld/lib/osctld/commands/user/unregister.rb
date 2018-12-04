require 'osctld/commands/base'

module OsCtld
  class Commands::User::Unregister < Commands::Base
    handle :user_unregister

    def execute
      if opts[:all]
        DB::Users.get do |users|
          users.each do |u|
            next if opts[:pool] && u.pool.name != opts[:pool]
            next unless u.registered?

            begin
              unregister_user(u)

            rescue ResourceLocked => e
              progress("User #{u.ident} is locked, skipping")
            end
          end
        end

      else
        DB::Users.sync do
          u = DB::Users.find(opts[:name], opts[:pool])
          return error('user not found') unless u
          return ok unless u.registered?

          unregister_user(u)
        end
      end

      ok
    end

    protected
    def unregister_user(u)
      manipulate(u) do
        progress("Unregistering user #{u.ident}")
        SystemUsers.remove(u.sysusername)
        u.registered = false
      end
    end
  end
end
