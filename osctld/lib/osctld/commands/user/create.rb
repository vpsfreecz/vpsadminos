require 'fileutils'

module OsCtld
  class Commands::User::Create < Commands::Base
    handle :user_create

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def execute
      u = User.new(opts[:name], load: false)
      return error('user already exists') if UserList.contains?(u.name)

      u.exclusively do
        zfs(:create, nil, u.dataset)

        File.chown(0, opts[:ugid], u.userdir)
        File.chmod(0751, u.userdir)

        Dir.mkdir(u.homedir) unless Dir.exist?(u.homedir)
        File.chown(opts[:ugid], opts[:ugid], u.homedir)
        File.chmod(0751, u.homedir)

        u.configure(opts[:ugid], opts[:offset], opts[:size])
        u.register

        UserList.sync do
          UserList.add(u)
          call_cmd(Commands::User::SubUGIds)
        end

        UserControl::Supervisor.start_server(u)
      end

      ok
    end
  end
end
