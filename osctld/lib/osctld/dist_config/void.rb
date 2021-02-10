require 'osctld/dist_config/base'

module OsCtld
  class DistConfig::Void < DistConfig::Base
    distribution :void

    def set_hostname(opts)
      # /etc/hostname
      writable?(File.join(ctrc.rootfs, 'etc', 'hostname')) do |path|
        regenerate_file(path, 0644) do |f|
          f.puts(ct.hostname.local)
        end
      end

      # Hostname in void is set by /etc/runit/core-services/05-misc.sh.
      # Unfortunately, it tries to set it by writing to /proc/sys/kernel/hostname,
      # which an unprivileged container cannot do. We add out own service
      # to set the hostname using /bin/hostname, which uses a syscall that works.
      sv = File.join(
        ctrc.rootfs,
        'etc/runit/core-services',
        '10-vpsadminos-hostname.sh',
      )
      if writable?(sv)
        OsCtld::ErbTemplate.render_to(
          'dist_config/network/void/hostname',
          {},
          sv
        )
      end

      # Entry in /etc/hosts
      update_etc_hosts(opts[:original])

      # Apply hostname if the container is running
      if ct.running?
        begin
          ct_syscmd(ct, "hostname #{ct.hostname.local}")

        rescue SystemCommandFailed => e
          log(:warn, ct, "Unable to apply hostname: #{e.message}")
        end
      end
    end

    def network(_opts)
      tpl_base = 'dist_config/network/void'

      cmds = ct.netifs.map do |netif|
        OsCtld::ErbTemplate.render(
          File.join(tpl_base, netif.type.to_s),
          {netif: netif}
        )
      end

      sv = File.join(
        ctrc.rootfs,
        'etc/runit/core-services',
        '90-vpsadminos-network.sh'
      )
      File.write(sv, cmds.join("\n")) if writable?(sv)
    end

    def passwd(opts)
      # Without the -c switch, the password is not set (bug?)
      ret = ct_syscmd(
        ct,
        'chpasswd -c SHA512',
        stdin: "#{opts[:user]}:#{opts[:password]}\n",
        run: true,
        valid_rcs: :all
      )

      return true if ret.success?
      log(:warn, ct, "Unable to set password: #{ret.output}")
    end
  end
end
