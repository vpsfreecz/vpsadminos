require 'libosctl'
require 'osctld/user_control/commands/base'

module OsCtld
  class UserControl::Commands::CtAutodev < UserControl::Commands::Base
    handle :ct_autodev

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct
      return error('access denied') unless owns_ct?(ct)

      # Ensure the devices dir exist
      unless Dir.exist?(ct.devices_dir)
        Dir.mkdir(ct.devices_dir, 0550)
        File.chown(ct.root_host_uid, ct.root_host_gid, ct.devices_dir)
      end

      # Filter out devices that have to be created
      devices = ct.devices.select { |dev| dev.name }

      # Prepare device nodes on the host
      devices.each do |dev|
        path = File.join(ct.devices_dir, dev.name)

        begin
          st = File.stat(path)

          if (dev.type == :char && !st.chardev?) \
             || (dev.type == :block && !st.blockdev?) \
             || dev.major != st.rdev_major.to_s \
             || dev.minor != st.rdev_minor.to_s
            # The device is of an incorrect type
            File.unlink(path)

          else
            # Device already exists
            File.chown(ct.root_host_uid, ct.root_host_gid, path)
            chmod_device(dev.name, path)
            next
          end

        rescue Errno::ENOENT
          # pass
        end

        devdir = File.dirname(path)
        FileUtils.mkdir_p(devdir) unless Dir.exist?(devdir)
        syscmd("mknod #{path} #{dev.type_s} #{dev.major} #{dev.minor}")
        File.chown(ct.root_host_uid, ct.root_host_gid, path)
        chmod_device(dev.name, path)
      end

      ok(source: ct.devices_dir, devices: devices.map(&:name))
    end

    protected
    # Set access mode of the device as is on the host
    # @param dev_name [String] absolute device name
    # @param ct_dev_path [String] path of the device in /run/osctl/pools/.../devices/...
    def chmod_device(dev_name, ct_dev_path)
      File.chmod(device_access_mode(dev_name), ct_dev_path)
    end

    # Return device access mode for the device on the host, if it exists
    def device_access_mode(dev_name)
      st = File.stat(File.join('/', dev_name))
      st.mode & 07777

    rescue Errno::ENOENT
      0644
    end
  end
end
