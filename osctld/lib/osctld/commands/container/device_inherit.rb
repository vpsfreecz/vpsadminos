require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::DeviceInherit < Commands::Logged
    handle :ct_device_inherit

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) { inherit(ct) }
    end
  end
end
