module OsCtld
  class Commands::Group::DeviceUnsetInherit < Commands::Logged
    handle :group_device_unset_inherit

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      grp.exclusively do
        unset_inherit(grp)
      end
    end
  end
end
