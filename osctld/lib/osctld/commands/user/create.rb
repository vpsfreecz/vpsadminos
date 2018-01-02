require 'fileutils'

module OsCtld
  class Commands::User::Create < Commands::Base
    handle :user_create

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      pool = DB::Pools.get_or_default(opts[:pool])
      return error('pool not found') unless pool

      u = User.new(pool, opts[:name], load: false)
      return error('user already exists') if DB::Users.contains?(u.name, pool)

      u.exclusively do
        zfs(:create, nil, u.dataset)

        File.chown(0, opts[:ugid], u.userdir)
        File.chmod(0751, u.userdir)

        Dir.mkdir(u.homedir) unless Dir.exist?(u.homedir)
        File.chown(opts[:ugid], opts[:ugid], u.homedir)
        File.chmod(0751, u.homedir)

        u.configure(opts[:ugid], opts[:offset], opts[:size])
        u.register

        DB::Users.sync do
          DB::Users.add(u)
          call_cmd(Commands::User::SubUGIds)
        end

        UserControl::Supervisor.start_server(u)
      end

      ok
    end
  end
end
