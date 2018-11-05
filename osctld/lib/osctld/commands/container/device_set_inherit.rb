require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::DeviceSetInherit < Commands::Logged
    handle :ct_device_set_inherit

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) { set_inherit(ct) }
    end
  end
end
