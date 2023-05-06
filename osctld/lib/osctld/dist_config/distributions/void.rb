require 'osctld/dist_config/distributions/base'

module OsCtld
  class DistConfig::Distributions::Void < DistConfig::Distributions::Base
    distribution :void

    class Configurator < DistConfig::Configurator
      def set_hostname(new_hostname, old_hostname: nil)
        # /etc/hostname
        writable?(File.join(rootfs, 'etc', 'hostname')) do |path|
          regenerate_file(path, 0644) do |f|
            f.puts(new_hostname.local)
          end
        end

        # Hostname in void is set by /etc/runit/core-services/05-misc.sh.
        # Unfortunately, it tries to set it by writing to /proc/sys/kernel/hostname,
        # which an unprivileged container cannot do. We add out own service
        # to set the hostname using /bin/hostname, which uses a syscall that works.
        sv = File.join(
          rootfs,
          'etc/runit/core-services',
          '10-vpsadminos-hostname.sh',
        )

        if writable?(sv)
          OsCtld::ErbTemplate.render_to_if_changed(
            'dist_config/network/void/hostname',
            {},
            sv
          )
        end
      end

      def network(netifs)
        tpl_base = 'dist_config/network/void'

        cmds = netifs.map do |netif|
          OsCtld::ErbTemplate.render(
            File.join(tpl_base, netif.type.to_s),
            {netif: netif}
          )
        end

        sv = File.join(
          rootfs,
          'etc/runit/core-services',
          '90-vpsadminos-network.sh'
        )
        File.write(sv, cmds.join("\n")) if writable?(sv)
      end

      protected
      def network_class
        nil
      end
    end

    # See man runit-init
    def stop(opts)
      # Configure runit for halt
      begin
        ContainerControl::Commands::StopRunit.run!(ct, message: opts[:message])
      rescue ContainerControl::Error => e
        log(:warn, ct, "Unable to gracefully shutdown runit: #{e.message}")
      end

      # Run standard stop process
      super(opts.merge(message: nil))
    end

    def apply_hostname
      begin
        ct_syscmd(ct, ['hostname', ct.hostname.local])

      rescue SystemCommandFailed => e
        log(:warn, ct, "Unable to apply hostname: #{e.message}")
      end
    end

    def passwd(opts)
      # Without the -c switch, the password is not set (bug?)
      ret = ct_syscmd(
        ct,
        %w(chpasswd -c SHA512),
        stdin: "#{opts[:user]}:#{opts[:password]}\n",
        run: true,
        valid_rcs: :all
      )

      return true if ret.success?
      log(:warn, ct, "Unable to set password: #{ret.output}")
    end
  end
end
