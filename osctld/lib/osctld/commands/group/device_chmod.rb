require 'osctld/commands/logged'

module OsCtld
  class Commands::Group::DeviceChmod < Commands::Logged
    handle :group_device_chmod

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      manipulate(grp) do
        chmod(grp)
      end
    end
  end
end
