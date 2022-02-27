require 'osctld/dist_config/network/base'

module OsCtld
  # Configure network using systemd-networkd
  #
  # https://www.freedesktop.org/software/systemd/man/systemd.network.html
  class DistConfig::Network::SystemdNetworkd < DistConfig::Network::Base
    def configure(netifs)
      netifs.each do |netif|
        do_create_netif(netif)
      end
    end

    def remove_netif(netifs, netif)
      do_remove_netif(netif.name)
    end

    def rename_netif(netifs, netif, old_name)
      do_remove_netif(old_name)
      do_create_netif(netif)
    end

    protected
    def do_create_netif(netif)
      f = network_file(netif.name)
      return unless writable?(f)

      OsCtld::ErbTemplate.render_to(
        File.join('dist_config/network/systemd_networkd', netif.type.to_s),
        {netif: netif},
        f,
      )
    end

    def do_remove_netif(name)
      f = network_file(name)
      return unless writable?(f)

      unlink_if_exists(f)
    end

    def network_file(name)
      File.join(rootfs, 'etc/systemd/network', "#{name}.network")
    end
  end
end
