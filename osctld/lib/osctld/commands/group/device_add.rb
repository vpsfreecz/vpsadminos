require 'osctld/commands/logged'

module OsCtld
  class Commands::Group::DeviceAdd < Commands::Logged
    handle :group_device_add

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      manipulate(grp) do
        add(grp, grp.root? ? nil : grp.parent)
      end
    end
  end
end
