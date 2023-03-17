require 'libosctl'
require 'osctld/devices/manager'

module OsCtld
  class Devices::V1::GroupManager < Devices::Manager
    include OsCtl::Lib::Utils::Log

    def assets(add)
      add.cgroup_device_list(
        group.abs_cgroup_path('devices'),
        desc: 'Controls access to devices',
        devices: devices,
      )
    end

    def parent
      group.root? ? nil : group.parent
    end

    def children
      group.children + group.containers
    end

    def configurator_class
      Devices::V1::GroupConfigurator
    end

    protected
    alias_method :group, :owner

    def add_to_changeset
      # not used on v1
    end
  end
end
