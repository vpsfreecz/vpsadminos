require 'osctld/commands/logged'

module OsCtld
  class Commands::User::Unset < Commands::Logged
    handle :user_unset

    def find
      u = DB::Users.find(opts[:name], opts[:pool])
      u || error!('user not found')
    end

    def execute(user)
      manipulate(user) do
        changes = {}

        opts.each do |k, v|
          case k
          when :attrs
            changes[k] = v
          end
        end

        user.unset(changes) if changes.any?
      end

      ok
    end
  end
end
