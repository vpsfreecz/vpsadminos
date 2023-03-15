require 'osctld/devices/v2/configurator'

module OsCtld
  class Devices::V2::ContainerConfigurator < Devices::V2::Configurator
    def init(devices)
      # Container cgroups need not be initialized, they'll be created & configured
      # on-demand when the container is starting from the ct_pre_start hook.
      get_prog(devices)
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
