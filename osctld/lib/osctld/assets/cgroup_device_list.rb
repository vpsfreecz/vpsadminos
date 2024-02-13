require 'osctld/assets/base'

module OsCtld
  # Check cgroupv1 devices.list
  class Assets::CgroupDeviceList < Assets::Base
    register :cgroup_device_list

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @param opts [Hash] options
    # @option opts [Array<Devices::Device>] devices
    def initialize(cgroup_path, opts)
      super
    end

    protected

    def validate(_run)
      begin
        devices_list = File.read(File.join(path, 'devices.list'))
      rescue Errno::ENOENT
        add_error("devices.list not found in cgroup #{path.inspect}")
      end

      cgroup_devices = devices_list.strip.split("\n")
      allowed_devices = opts[:devices].map(&:to_s)

      allowed_devices.delete_if do |dev|
        if cgroup_devices.delete(dev)
          true
        else
          add_error("device #{dev.inspect} not allowed")
          false
        end
      end

      cgroup_devices.each do |dev|
        add_error("device #{dev.inspect} allowed, but not configured")
      end
    end
  end
end
