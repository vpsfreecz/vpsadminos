require 'osctld/commands/base'
require 'fileutils'

module OsCtld
  class Commands::User::Setup < Commands::Base
    handle :user_setup

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      u = opts[:user]

      manipulate(u) do
        if Dir.exist?(u.userdir)
          File.chmod(0751, u.userdir)
        else
          Dir.mkdir(u.userdir, 0751)
        end

        File.chown(0, u.ugid, u.userdir)

        if Dir.exist?(u.homedir)
          File.chmod(0751, u.homedir)
        else
          Dir.mkdir(u.homedir, 0751)
        end

        File.chown(u.ugid, u.ugid, u.homedir)

        DB::Users.add(u)
        UserControl::Supervisor.start_server(u)
      end

      ok
    end
  end
end
