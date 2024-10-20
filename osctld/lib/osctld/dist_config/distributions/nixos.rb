require 'osctld/dist_config/distributions/base'

module OsCtld
  class DistConfig::Distributions::NixOS < DistConfig::Distributions::Base
    distribution :nixos

    class Configurator < DistConfig::Configurator
      def network(netifs)
        tpl_base = 'dist_config/network/nixos'

        %w[add del].each do |operation|
          cmds = netifs.map do |netif|
            OsCtld::ErbTemplate.render(
              File.join(tpl_base, netif.type.to_s),
              { netif:, op: operation }
            )
          end

          writable?(File.join(rootfs, "ifcfg.#{operation}")) do |path|
            File.write(path, cmds.join("\n"))
          end
        end
      end

      protected

      def network_class
        nil
      end
    end

    def post_mount(opts)
      super
      return if ct.impermanence.nil?

      ContainerControl::Commands::WithMountns.run!(
        ct,
        ns_pid: opts[:ns_pid],
        chroot: opts[:rootfs_mount],
        block: proc do
          # If /sbin/init already exists, it means we're *not* in impermanence mode
          # right now, even if it is enabled. While in impermanence mode, we start
          # with an empty dataset. Existing /sbin/init suggest custom `osctl ct boot`
          # is active.
          next if File.exist?('/sbin/init')

          begin
            Dir.mkdir('/sbin')
          rescue Errno::EEXIST
            # pass
          end

          File.symlink('/nix/var/nix/profiles/system/init', '/sbin/init')
          true
        end
      )
    end

    def set_hostname(_opts = {})
      log(:warn, 'Unable to apply hostname to NixOS container')
    end

    def update_etc_hosts(_opts = {})
      # not supported
    end

    def unset_etc_hosts(_opts = {})
      # not supported
    end

    def bin_path(_opts)
      with_rootfs do
        File.realpath('/nix/var/nix/profiles/system/sw/bin')
      rescue Errno::ENOENT
        '/bin'
      end
    end
  end
end
