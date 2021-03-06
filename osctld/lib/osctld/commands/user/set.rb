require 'osctld/commands/logged'

module OsCtld
  class Commands::User::Set < Commands::Logged
    handle :user_set

    def find
      u = DB::Users.find(opts[:name], opts[:pool])
      u || error!('user not found')
    end

    def execute(user)
      manipulate(user) do
        changes = {}

        opts.each do |k, v|
          case k
          when :standalone, :attrs
            changes[k] = v
          end
        end

        user.set(changes) if changes.any?
      end

      ok
    end
  end
end
