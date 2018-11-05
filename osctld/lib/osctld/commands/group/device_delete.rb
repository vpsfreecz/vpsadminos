require 'osctld/commands/logged'

module OsCtld
  class Commands::Group::DeviceDel < Commands::Logged
    handle :group_device_delete

    include OsCtl::Lib::Utils::Log
    include Utils::Devices

    def find
      grp = DB::Groups.find(opts[:name], opts[:pool])
      grp || error!('group not found')
    end

    def execute(grp)
      manipulate(grp) do
        dev = grp.devices.find(opts[:type].to_sym, opts[:major], opts[:minor])
        error!('device not found') unless dev

        if dev.inherited?
          error!('inherited devices cannot be removed, use chmod to restrict access')

        elsif !opts[:recursive] && grp.devices.used_by_descendants?(dev)
          error!('device is used by child groups/containers, use recursive mode')
        end

        grp.devices.remove_recursive(dev)
        ok
      end
    end
  end
end
