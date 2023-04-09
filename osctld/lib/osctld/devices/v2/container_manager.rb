require 'osctld/devices/manager'

module OsCtld
  class Devices::V2::ContainerManager < Devices::Manager
    def assets(add)
      add.cgroup_program(
        ct.abs_apply_cgroup_path('devices'),
        desc: 'Controls access to devices',
        program_name: configurator.prog_name,
        attach_type: 'device',
        attach_flags: 'multi',
        optional: true,
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
        changed = false

        devices.delete_if do |dev|
          pdev = parent.devices.get(dev)
          delete = pdev.nil? || !pdev.mode.compatible?(dev.mode)
          changed = true if delete
          delete
        end

        add_to_changeset if changed
      end
    end

    def parent
      ct.group
    end

    def children
      []
    end

    def configurator_class
      Devices::V2::ContainerConfigurator
    end

    def changeset_sort_key
      File.join(ct.group.name, ct.id)
    end

    protected
    alias_method :ct, :owner
  end
end
