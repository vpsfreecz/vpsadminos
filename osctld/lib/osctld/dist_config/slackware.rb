require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::Slackware < DistConfig::Base
    distribution :slackware

    def set_hostname(opts)
      # /etc/hostname
      writable?(File.join(ctrc.rootfs, 'etc', 'HOSTNAME')) do |path|
        regenerate_file(path, 0644) do |f|
          f.puts(ct.hostname.local)
        end
      end

      # Entry in /etc/hosts
      update_etc_hosts(opts[:original])

      # Apply hostname if the container is running
      if ct.running?
        begin
          ct_syscmd(ct, 'hostname -F /etc/HOSTNAME')

        rescue SystemCommandFailed => e
          log(:warn, ct, "Unable to apply hostname: #{e.message}")
        end
      end
    end

    def network(_opts)
      tpl_base = 'dist_config/network/slackware'

      {start: 'add', stop: 'del'}.each do |operation, cmd|
        cmds = ct.netifs.map do |netif|
          OsCtld::ErbTemplate.render(
            File.join(tpl_base, netif.type.to_s),
            {netif: netif, cmd: cmd}
          )
        end

        writable?(File.join(ctrc.rootfs, 'etc/rc.d', "rc.venet.#{operation}")) do |path|
          File.write(path, cmds.join("\n"))
        end
      end
    end
  end
end
