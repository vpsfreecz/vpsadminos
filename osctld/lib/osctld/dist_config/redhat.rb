require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::RedHat < DistConfig::Base

    class Configurator < DistConfig::Configurator
      def set_hostname(new_hostname, old_hostname: nil)
        # /etc/sysconfig/network
        set_params(
          File.join(rootfs, 'etc', 'sysconfig', 'network'),
          {'HOSTNAME' => new_hostname.local}
        )
      end

      def network(netifs)
        set_params(
          File.join(rootfs, 'etc/sysconfig/network'),
          {'NETWORKING' => 'yes'}
        )

        netifs.each do |netif|
          do_create_netif(netif)
        end

        setup_for_nm(netifs) if use_nm?
      end

      # Cleanup old config files
      def remove_netif(netifs, netif)
        do_remove_netif(netif.name)
        setup_for_nm(netifs) if use_nm?
      end

      # Rename config files
      def rename_netif(netifs, netif, old_name)
        do_remove_netif(old_name)
        do_create_netif(netif)
        setup_for_nm(netifs) if use_nm?
      end

      protected
      # @return [:network_manager, :initscripts]
      def config_backend
        raise NotImplementedError
      end

      def use_nm?
        config_backend == :network_manager
      end

      def use_initscripts?
        config_backend == :initscripts
      end

      def template_dir
        use_nm? ? 'redhat_nm' : 'redhat_initscripts'
      end

      def do_create_netif(netif)
        tpl_base = File.join('dist_config/network', template_dir)
        ct_base = File.join(rootfs, 'etc', 'sysconfig')
        ifcfg = File.join(ct_base, 'network-scripts', "ifcfg-#{netif.name}")

        return unless writable?(ifcfg)

        OsCtld::ErbTemplate.render_to(
          File.join(tpl_base, netif.type.to_s, 'ifcfg'),
          {netif: netif},
          ifcfg
        )

        if netif.type == :routed
          netif.active_ip_versions.each do |ip_v|
            OsCtld::ErbTemplate.render_to(
              File.join(tpl_base, netif.type.to_s, "route_v#{ip_v}"),
              {netif: netif},
              File.join(
                ct_base,
                'network-scripts',
                "route#{ip_v == 6 ? '6' : ''}-#{netif.name}"
              )
            )
          end
        end
      end

      def do_remove_netif(name)
        base = File.join(rootfs, 'etc', 'sysconfig', 'network-scripts')
        files = [
          "ifcfg-#{name}",
          "route-#{name}",
          "route6-#{name}"
        ]

        files.each do |f|
          path = File.join(base, f)
          next if !File.exist?(path) || !writable?(path)

          File.unlink(path)
        end
      end

      def setup_for_nm(netifs)
        generate_nm_conf(netifs)
        generate_nm_udev_rules(netifs)
      end

      def generate_nm_conf(netifs)
        conf_d = File.join(rootfs, 'etc', 'NetworkManager', 'conf.d')
        return unless Dir.exist?(conf_d)

        file = File.join(conf_d, 'osctl.conf')
        return unless writable?(file)

        OsCtld::ErbTemplate.render_to(
          File.join('dist_config/network/redhat_nm/nm_conf'),
          {netifs: netifs},
          file,
        )
      end

      def generate_nm_udev_rules(netifs)
        rules_d = File.join(rootfs, 'etc', 'udev', 'rules.d')
        return unless Dir.exist?(rules_d)

        file = File.join(rules_d, '86-osctl.rules')
        return unless writable?(file)

        OsCtld::ErbTemplate.render_to(
          File.join('dist_config/network/redhat_nm/udev_rules'),
          {netifs: netifs},
          file,
        )
      end

      # @param file [String]
      # @param params [Hash]
      def set_params(file, params)
        return unless writable?(file)

        regenerate_file(file, 0644) do |new, old|
          if old
            # Overwrite existing params and keep unchanged ones
            old.each_line do |line|
              param, value = params.detect { |k, v| /^#{k}=/ =~ line }

              if param
                new.puts("#{param}=\"#{value}\"")
                params.delete(param)

              else
                new.write(line)
              end
            end

            # Write new params
            params.each do |k, v|
              new.puts("#{k}=\"#{v}\"")
            end

          else
            # File did not exist, write all params
            params.each do |k, v|
              new.puts("#{k}=\"#{v}\"")
            end
          end
        end
      end
    end

    def apply_hostname
      begin
        ct_syscmd(ct, ['hostname', ct.hostname.fqdn])

      rescue SystemCommandFailed => e
        log(:warn, ct, "Unable to apply hostname: #{e.message}")
      end
    end
  end
end
