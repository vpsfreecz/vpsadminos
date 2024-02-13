require 'osctld/devices/manager'

module OsCtld
  class Devices::V1::ContainerManager < Devices::Manager
    def assets(add)
      add.cgroup_device_list(
        ct.abs_apply_cgroup_path('devices'),
        desc: 'Controls access to devices',
        devices:
      )
    end

    # Check that all devices are provided by parents, or raise an exception
    # @param group [Group, nil] which group to use as the container's parent,
    #                           defaults to the container's group
    def check_all_available!(group: nil)
      sync do
        devices.each { |dev| check_availability!(dev, parent: group || ct.group) }
      end
    end

    # Ensure that all required devices are provided by parent groups
    def ensure_all
      sync do
        devices.each { |dev| parent.devices.provide(dev) }
      end
    end

    # Remove devices that aren't provided by the parent, or have insufficient
    # access mode
    def remove_missing
      sync do
        devices.delete_if do |dev|
          pdev = parent.devices.get(dev)
          pdev.nil? || !pdev.mode.compatible?(dev.mode)
        end
      end
    end

    def parent
      ct.group
    end

    def children
      []
    end

    def configurator_class
      Devices::V1::ContainerConfigurator
    end

    protected

    alias ct owner

    def add_to_changeset
      # not used on v1
    end

    # @param devices [Devices::Manager]
    # @param path [String] absolute cgroup path
    def apply_devices(devices, path)
      return if CGroup.v2?

      devices.each do |dev|
        CGroup.set_param(File.join(path, 'devices.allow'), [dev.to_s])
      end
    end
  end
end
