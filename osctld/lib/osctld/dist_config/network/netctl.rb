require 'osctld/dist_config/network/base'

module OsCtld
  # Configure network using netctl
  #
  # https://wiki.archlinux.org/title/netctl
  class DistConfig::Network::Netctl < DistConfig::Network::Base
    def usable?
      Dir.exist?(File.join(rootfs, 'etc/netctl'))
    end

    def configure(netifs)
      netifs.each do |netif|
        do_create_netif(netif)
      end
    end

    # Remove netctl profile and systemd service
    def remove_netif(netifs, netif)
      do_remove_netif(netif.name)
    end

    # Rename netctl profile and systemd service
    def rename_netif(netifs, netif, old_name)
      # Remove old network interface
      do_remove_netif(old_name)

      # Create the new interface
      do_create_netif(netif)
    end

    protected
    def do_create_netif(netif)
      profile = netctl_profile(netif.name)
      return unless writable?(profile)

      # Create netctl profile
      OsCtld::ErbTemplate.render_to(
        File.join('dist_config/network/netctl', netif.type.to_s),
        {netif: netif},
        profile
      )

      s_name = service_name(netif.name)

      # Remove deprecated systemd override
      unlink_if_exists(deprecated_service_path(netif.name))

      # Start the service on boot
      s_link = service_symlink(netif.name)

      if !File.symlink?(s_link) && !File.exist?(s_link)
        File.symlink(File.join('/etc/systemd/system', s_name), s_link)
      end
    end

    def do_remove_netif(name)
      profile = netctl_profile(name)
      return unless writable?(profile)

      # Disable the service
      s_link = service_symlink(name)
      File.unlink(s_link) if File.symlink?(s_link)

      # Remove deprecated service override file
      unlink_if_exists(deprecated_service_path(name))

      # Remove netctl profile
      File.unlink(profile) if File.exist?(profile)
    end

    def netctl_profile(name)
      File.join(rootfs, 'etc/netctl', name)
    end

    def service_name(name)
      "netctl@#{name}.service"
    end

    def deprecated_service_path(name)
      File.join(rootfs, 'etc/systemd/system', service_name(name))
    end

    def service_symlink(name)
      File.join(
        rootfs,
        'etc/systemd/system/multi-user.target.wants',
        service_name(name)
      )
    end
  end
end
