require 'osctld/commands/base'

module OsCtld
  class Commands::Container::DeviceList < Commands::Base
    handle :ct_device_list

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.inclusively do
        list(ct, opts)
      end
    end
  end
end
