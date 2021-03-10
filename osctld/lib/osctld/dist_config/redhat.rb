require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::RedHat < DistConfig::Base
    def set_hostname(opts)
      # /etc/sysconfig/network
      set_params(
        File.join(ctrc.rootfs, 'etc', 'sysconfig', 'network'),
        {'HOSTNAME' => ct.hostname.local}
      )

      # Entry in /etc/hosts
      update_etc_hosts(opts[:original])

      # Apply hostname if the container is running
      if ct.running?
        begin
          ct_syscmd(ct, "hostname #{ct.hostname}")

        rescue SystemCommandFailed => e
          log(:warn, ct, "Unable to apply hostname: #{e.message}")
        end
      end
    end

    def network(_opts)
      set_params(
        File.join(ctrc.rootfs, 'etc/sysconfig/network'),
        {'NETWORKING' => 'yes'}
      )

      ct.netifs.each do |netif|
        do_create_netif(netif)
      end

      generate_nm_conf if use_nm?
    end

    # Cleanup old config files
    def remove_netif(opts)
      do_remove_netif(opts[:netif].name)
      generate_nm_conf if use_nm?
    end

    # Rename config files
    def rename_netif(opts)
      do_remove_netif(opts[:original_name])
      do_create_netif(opts[:netif])
      generate_nm_conf if use_nm?
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
      ct_base = File.join(ctrc.rootfs, 'etc', 'sysconfig')
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
      base = File.join(ctrc.rootfs, 'etc', 'sysconfig', 'network-scripts')
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

    def generate_nm_conf
      conf_d = File.join(ctrc.rootfs, 'etc', 'NetworkManager', 'conf.d')
      return unless Dir.exist?(conf_d)

      file = File.join(conf_d, 'osctl.conf')
      return unless writable?(file)

      OsCtld::ErbTemplate.render_to(
        File.join('dist_config/network/redhat_nm/nm_conf'),
        {netifs: ct.netifs},
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
end
