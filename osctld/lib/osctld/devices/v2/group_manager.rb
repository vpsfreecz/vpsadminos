require 'osctld/devices/manager'

module OsCtld
  class Devices::V2::GroupManager < Devices::Manager
    def assets(add)
      add.cgroup_program(
        group.abs_cgroup_path('devices'),
        desc: 'Controls access to devices',
        program_name: configurator.prog_name,
        attach_type: 'cgroup_device',
        attach_flags: 'multi',
      )
    end

    def parent
      group.parent
    end

    def children
      group.children
    end

    def configurator_class
      Devices::V2::GroupConfigurator
    end

    def changeset_sort_key
      group.name
    end

    protected
    alias_method :group, :owner
  end
end
