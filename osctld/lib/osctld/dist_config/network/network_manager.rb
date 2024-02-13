require 'osctld/dist_config/network/base'

module OsCtld
  # Configure network using NetworkManager keyfiles
  class DistConfig::Network::NetworkManager < DistConfig::Network::Base
    def usable?
      begin
        network_scripts = File.join(rootfs, 'etc/sysconfig/network-scripts')

        Dir.entries(network_scripts).each do |entry|
          return false if entry.start_with?('ifcfg-')
        end
      rescue Errno::ENOENT, Errno::ENOTDIR
        # pass
      end

      return false unless Dir.exist?(File.join(rootfs, 'etc/NetworkManager/conf.d'))
      return false unless Dir.exist?(File.join(rootfs, 'etc/NetworkManager/system-connections'))

      service = 'NetworkManager.service'

      # Check the service is not masked
      return false if systemd_service_masked?(service)

      # Check the service is enabled
      return false unless systemd_service_enabled?(service, 'multi-user.target')

      true
    end

    def configure(netifs)
      netifs.each do |netif|
        do_create_connection(netif)
      end

      setup_nm(netifs)
    end

    # Cleanup old config files
    def remove_netif(netifs, netif)
      do_remove_connection(netif.name)
      setup_nm(netifs)
    end

    # Rename config files
    def rename_netif(netifs, netif, old_name)
      do_remove_connection(old_name)
      do_create_connection(netif)
      setup_nm(netifs)
    end

    protected

    def do_create_connection(netif)
      tpl_base = File.join('dist_config/network/network_manager')
      ct_base = File.join(rootfs, 'etc', 'NetworkManager/system-connections')
      keyfile = File.join(ct_base, "#{netif.name}.nmconnection")

      return unless writable?(keyfile)

      OsCtld::ErbTemplate.render_to_if_changed(
        File.join(tpl_base, netif.type.to_s),
        { netif: },
        keyfile,
        perm: 0o600
      )
    end

    def do_remove_connection(name)
      base = File.join(rootfs, 'etc', 'NetworkManager', 'system-connections')
      files = [
        "#{name}.nmconnection"
      ]

      files.each do |f|
        path = File.join(base, f)
        next if !File.exist?(path) || !writable?(path)

        File.unlink(path)
      end
    end

    def setup_nm(netifs)
      generate_nm_conf(netifs)
      generate_nm_udev_rules(netifs)
    end

    def generate_nm_conf(netifs)
      conf_d = File.join(rootfs, 'etc', 'NetworkManager', 'conf.d')
      return unless Dir.exist?(conf_d)

      file = File.join(conf_d, 'osctl.conf')
      return unless writable?(file)

      OsCtld::ErbTemplate.render_to_if_changed(
        File.join('dist_config/network/network_manager/nm_conf'),
        { netifs: },
        file
      )
    end

    def generate_nm_udev_rules(netifs)
      rules_d = File.join(rootfs, 'etc', 'udev', 'rules.d')
      return unless Dir.exist?(rules_d)

      file = File.join(rules_d, '86-osctl.rules')
      return unless writable?(file)

      OsCtld::ErbTemplate.render_to_if_changed(
        File.join('dist_config/network/network_manager/udev_rules'),
        { netifs: },
        file
      )
    end
  end
end
