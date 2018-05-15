require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::DevicePromote < Commands::Logged
    handle :ct_device_promote

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        promote(ct)
      end
    end
  end
end
