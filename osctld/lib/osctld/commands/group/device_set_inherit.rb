module OsCtld
  class Commands::Group::DeviceSetInherit < Commands::Logged
    handle :group_device_set_inherit

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      grp.exclusively do
        set_inherit(grp)
      end
    end
  end
end
