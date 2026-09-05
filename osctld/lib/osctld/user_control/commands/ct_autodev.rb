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

      ret = authenticate_lifecycle_callback(ct)
      return ret if ret

      with_claimed_lifecycle_event(ct, :autodev, after: :post_mount) do
        # Filter out devices that have to be created
        devices = ct.devices.select { |dev| dev.can_create? && dev.name }.map do |dev|
          dev.export.merge(
            type_s: dev.type_s,
            permission: device_access_mode(dev.name)
          )
        end

        ok(devices:)
      end
    end

    protected

    # LXC runs autodev from its cloned setup child, which forks the hook.
    def lifecycle_peer_depth
      2
    end

    # Return device access mode for the device on the host, if it exists
    def device_access_mode(dev_name)
      st = File.stat(File.join('/', dev_name))
      st.mode & 0o7777
    rescue Errno::ENOENT
      0o644
    end
  end
end
