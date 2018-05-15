require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::Arch < DistConfig::Base
    distribution :arch

    def set_hostname(opts)
      # /etc/hostname
      regenerate_file(File.join(ct.rootfs, 'etc', 'hostname'), 0644) do |f|
        f.puts(ct.hostname)
      end

      # Entry in /etc/hosts
      update_etc_hosts(opts[:original])

      # Apply hostname if the container is running
      if ct.running?
        begin
          ct_syscmd(ct, 'hostname -F /etc/hostname')

        rescue SystemCommandFailed => e
          log(:warn, ct, "Unable to apply hostname: #{e.message}")
        end
      end
    end

    def network(_opts)
      ct.netifs.each do |netif|
        do_create_netif(netif)
      end
    end

    # Remove netctl profile and systemd service
    def remove_netif(opts)
      do_remove_netif(opts[:netif].name)
    end

    # Rename netctl profile and systemd service
    def rename_netif(opts)
      # Remove old network interface
      do_remove_netif(opts[:original_name])

      # Create the new interface
      do_create_netif(opts[:netif])
    end

    protected
    def do_create_netif(netif)
      # Create netctl profile
      OsCtld::Template.render_to(
        File.join('dist_config/network/arch', netif.type.to_s),
        {netif: netif},
        netctl_profile(netif.name)
      )

      s_name = service_name(netif.name)
      s_path = service_path(netif.name)

      # Create systemd service for netctl
      OsCtld::Template.render_to(
        'dist_config/network/arch/service',
        {netif: netif},
        s_path
      )

      # Start the service on boot
      s_link = service_symlink(netif.name)

      if !File.symlink?(s_link) && !File.exist?(s_link)
        File.symlink(File.join('/etc/systemd/system', s_name), s_link)
      end
    end

    def do_remove_netif(name)
      # Disable the service
      s_link = service_symlink(name)
      File.unlink(s_link) if File.symlink?(s_link)

      # Remove the service
      s_path = service_path(name)
      File.unlink(s_path) if File.symlink?(s_path)

      # Remove netctl profile
      profile = netctl_profile(name)
      File.unlink(profile) if File.exist?(profile)
    end

    def netctl_profile(name)
      File.join(ct.rootfs, 'etc/netctl', name)
    end

    def service_name(name)
      "netctl@#{name}.service"
    end

    def service_path(name)
      File.join(ct.rootfs, 'etc/systemd/system', service_name(name))
    end

    def service_symlink(name)
      File.join(
        ct.rootfs,
        'etc/systemd/system/multi-user.target.wants',
        service_name(name)
      )
    end
  end
end
