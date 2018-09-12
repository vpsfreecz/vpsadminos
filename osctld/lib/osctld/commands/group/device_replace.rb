require 'osctld/commands/logged'

module OsCtld
  class Commands::Group::DeviceReplace < Commands::Logged
    handle :group_device_replace

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      grp.exclusively do
        replace(grp)
      end
    end
  end
end
