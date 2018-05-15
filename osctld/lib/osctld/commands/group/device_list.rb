require 'osctld/commands/base'

module OsCtld
  class Commands::Group::DeviceList < Commands::Base
    handle :group_device_list

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def execute
      grp = DB::Groups.find(opts[:name], opts[:pool])
      error!('group not found') unless grp

      grp.inclusively do
        list(grp, opts)
      end
    end
  end
end
