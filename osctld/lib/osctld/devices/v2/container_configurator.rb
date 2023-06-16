require 'osctld/devices/v2/configurator'

module OsCtld
  class Devices::V2::ContainerConfigurator < Devices::V2::Configurator
    def init(devices)
      # Container cgroups need not be initialized, they'll be created & configured
      # on-demand when the container is starting from the ct_pre_start hook.
      get_prog(devices)
    end

    def reconfigure(devices)
      # Containers that haven't been started yet do not have their cgroup created
      if CGroup.exist?(abs_cgroup_path)
        attach_prog(devices)
      end
    end

    protected
    def cgroup_path
      owner.base_cgroup_path
    end

    def abs_cgroup_path
      owner.abs_apply_cgroup_path('devices')
    end
  end
end
