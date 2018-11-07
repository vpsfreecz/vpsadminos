require 'osctld/commands/logged'

module OsCtld
  class Commands::User::Delete < Commands::Logged
    handle :user_delete

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def find
      u = DB::Users.find(opts[:name], opts[:pool])
      u || error!('user not found')
    end

    def execute(u)
      error!('user has container(s)') if u.has_containers?

      manipulate(u) do
        UserControl::Supervisor.stop_server(u)

        # Double-check user's containers, for only within the lock
        # can we be sure
        error!('user has container(s)') if u.has_containers?

        call_cmd!(Commands::User::Unregister, name: u.name, pool: u.pool.name)

        zfs(:destroy, nil, u.dataset)
        File.unlink(u.config_path)

        DB::Users.remove(u)
        call_cmd(Commands::User::SubUGIds)
      end

      ok
    end
  end
end
