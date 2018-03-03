module OsCtld
  class Commands::Container::DeviceDelete < Commands::Logged
    handle :ct_device_delete

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        dev = ct.devices.find(opts[:type].to_sym, opts[:major], opts[:minor])
        error!('device not found') unless dev

        if dev.inherited?
          error!('inherited devices cannot be removed, use chmod to restrict access')
        end

        ct.devices.remove(dev)
        ok
      end
    end
  end
end
