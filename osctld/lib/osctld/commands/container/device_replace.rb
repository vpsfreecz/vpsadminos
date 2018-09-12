require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::DeviceReplace < Commands::Logged
    handle :ct_device_replace

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        replace(ct)
      end
    end
  end
end
