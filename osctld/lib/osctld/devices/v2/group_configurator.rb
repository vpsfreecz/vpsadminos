require 'osctld/devices/v2/configurator'

module OsCtld
  class Devices::V2::GroupConfigurator < Devices::V2::Configurator
    def init(devices)
      CGroup.mkpath('devices', cgroup_path.split('/'))
      get_prog(devices)
      attach_prog(devices)
    end

    protected
    def cgroup_path
      owner.cgroup_path
    end

    def abs_cgroup_path
      owner.abs_cgroup_path('devices')
    end
  end
end
