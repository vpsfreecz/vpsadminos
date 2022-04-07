require 'osctld/dist_config/network/base'

module OsCtld
  # Configure network using netifrc
  #
  # https://wiki.gentoo.org/wiki/Netifrc
  class DistConfig::Network::Netifrc < DistConfig::Network::Base
    def usable?
      File.executable?(File.join(rootfs, 'etc/init.d/net.lo')) \
        && Dir.exist?(File.join(rootfs, 'etc/conf.d'))
    end

    def configure(netifs)
      netifs.each do |netif|
        do_create_netif(netif)
      end

      update_confd_net(netifs)
    end

    # Remove init script
    def remove_netif(netifs, netif)
      do_remove_netif(netif.name)
      update_confd_net(netifs)
    end

    # Rename init script
    def rename_netif(netifs, netif, old_name)
      # Remove old network interface
      do_remove_netif(old_name)

      # Create the new interface
      do_create_netif(netif)

      # Update /etc/conf.d/net
      update_confd_net(netifs)
    end

    protected
    def do_create_netif(netif)
      return unless writable?(netifrc_conf(netif.name))

      # Create netifrc config
      OsCtld::ErbTemplate.render_to_if_changed(
        File.join('dist_config/network/netifrc', netif.type.to_s),
        {netif: netif},
        netifrc_conf(netif.name)
      )

      # Create init script
      add_init_script(netif.name)
    end

    def do_remove_netif(name)
      return unless writable?(netifrc_conf(name))

      # Remove init script
      del_init_script(name)

      # Remove netifrc config
      File.unlink(netifrc_conf(name)) if File.exist?(netifrc_conf(name))
    end

    def add_init_script(name)
      # Create init script
      begin
        File.lstat(script_path(name))

      rescue Errno::ENOENT
        File.symlink('/etc/init.d/net.lo', script_path(name))
      end

      # Enable the init script in the default runlevel
      begin
        File.lstat(rc_path(name))

      rescue Errno::ENOENT
        File.symlink(File.join('/etc/init.d', "net.#{name}"), rc_path(name))
      end
    end

    def del_init_script(name)
      # Disable init script
      File.unlink(rc_path(name)) if File.symlink?(rc_path(name))

      # Remove init script
      File.unlink(script_path(name)) if File.symlink?(script_path(name))
    end

    def update_confd_net(netifs)
      config = File.join(rootfs, 'etc/conf.d/net')
      return unless writable?(config)

      heading = "# BEGIN osctld generated content"
      banner = <<-END
#
# Do not edit lines within BEGIN and END. This section is generated by osctld
# from vpsAdminOS. You can move this block around and add your own configuration
# above and below this block. To stop osctld from manipulating this file, run
#
#   chmod u-w /etc/conf.d/net

      END
      ending = "\n# END osctld generated content"

      cfg = netifs.map do |netif|
        ". #{File.join('/etc/conf.d', "net.#{netif.name}")}"
      end.join("\n")

      regenerate_file(config, 0644) do |new, old|
        if old.nil?
          # /etc/conf.d/net did not exist, create it
          new.puts(heading)
          new.puts(banner)
          new.puts(cfg)
          new.puts(ending)
          next
        end

        in_block = false
        done = false

        old.each_line do |line|
          if !done && line.strip.start_with?('# BEGIN osctld')
            in_block = true

          elsif in_block && !done && line.strip.start_with?('# END osctld')
            in_block = false
            done = true

            new.puts(heading)
            new.puts(banner)
            new.puts(cfg)
            new.puts(ending)

          elsif !in_block
            new.write(line)
          end
        end

        # Block not found
        unless done
          new.puts(heading)
          new.puts(banner)
          new.puts(cfg)
          new.puts(ending)
        end
      end
    end

    def netifrc_conf(name)
      File.join(rootfs, 'etc/conf.d', "net.#{name}")
    end

    def script_path(name)
      File.join(rootfs, 'etc/init.d', "net.#{name}")
    end

    def rc_path(name)
      File.join(rootfs, 'etc/runlevels/default', "net.#{name}")
    end
  end
end
