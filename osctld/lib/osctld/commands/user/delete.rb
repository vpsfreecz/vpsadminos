require 'osctld/commands/logged'

module OsCtld
  class Commands::User::Delete < Commands::Logged
    handle :user_delete

    def find
      u = DB::Users.find(opts[:name], opts[:pool])
      u || error!('user not found')
    end

    def execute(u)
      error!('user has container(s)') if u.has_containers?

      manipulate(u) do
        UserControl::Supervisor.stop_server(u)

        u.exclusively do
          # Double-check user's containers, for only within the lock
          # can we be sure
          error!('user has container(s)') if u.has_containers?
          u.delete
        end

        DB::Users.remove(u)
        call_cmd(Commands::User::SubUGIds)
      end

      ok
    end
  end
end
