require 'osctld/devices/configurator'

module OsCtld
  class Devices::V1::GroupConfigurator < Devices::Configurator
    def init(devices)
      log(:info, owner, "Configuring cgroup #{owner.cgroup_path} for devices")

      return unless CGroup.mkpath('devices', owner.cgroup_path.split('/'))

      reconfigure(devices)
    end

    def reconfigure(devices)
      clear
      do_configure(devices, owner.abs_cgroup_path('devices'))
    end

    def add_device(device)
      do_allow_device(device, owner.abs_cgroup_path('devices'))
    end

    def remove_device(device)
      do_deny_device(device, owner.abs_cgroup_path('devices'))
    end

    def apply_changes(changes)
      do_apply_changes(changes, owner.abs_cgroup_path('devices'))
    end

    protected

    def clear
      return if @cleared

      do_deny_all(owner.abs_cgroup_path('devices'))
      @cleared = true
    end

    def do_deny_all(path)
      CGroup.set_param(
        File.join(path, 'devices.deny'),
        ['a']
      )
    end

    def do_allow_device(device, path)
      CGroup.set_param(
        File.join(path, 'devices.allow'),
        [device.to_s]
      )
    end

    def do_deny_device(device, path)
      CGroup.set_param(
        File.join(path, 'devices.deny'),
        [device.to_s]
      )
    end

    def do_configure(devices, path)
      devices.each { |dev| do_allow_device(dev, path) }
    end

    def do_apply_changes(changes, path)
      changes.each do |action, value|
        case action
        when :allow
          CGroup.set_param(
            File.join(path, 'devices.allow'),
            [value]
          )

        when :deny
          CGroup.set_param(
            File.join(path, 'devices.deny'),
            [value]
          )
        end
      end
    end
  end
end
