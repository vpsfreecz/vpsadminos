module OsCtld
  class DistConfig::Debian < DistConfig::Base
    distribution :debian

    def set_hostname(opts)
      etc = File.join(ct.rootfs, 'etc')
      hostname = File.join(etc, 'hostname')
      hosts = File.join(etc, 'hosts')

      # /etc/hostname
      File.open("#{hostname}.new", 'w') do |f|
        f.puts(ct.hostname)
      end

      File.rename("#{hostname}.new", hostname)

      # Entry in /etc/hosts
      dst = File.open("#{hosts}.new", 'w')

      File.open(hosts, 'r') do |src|
        src.each_line do |line|
          if (/^127\.0\.0\.1\s/ =~ line || /^::1\s/ =~ line) \
             && !includes_hostname?(line, ct.hostname)

            if opts[:original] && includes_hostname?(line, opts[:original])
              line.sub!(/\s#{Regexp.escape(opts[:original])}/, '')
            end

            dst.puts("#{line.rstrip} #{ct.hostname}")
          else
            dst.write(line)
          end
        end
      end

      dst.close

      File.rename("#{hosts}.new", hosts)

      # Apply hostname if the container is running
      if ct.running?
        begin
          ct_syscmd(ct, 'hostname -F /etc/hostname')

        rescue RuntimeError => e
          log(:warn, ct, "Unable to apply hostname: #{e.message}")
        end
      end
    end

    def network(_opts)
      base = File.join(ct.rootfs, 'etc', 'network')
      vars = {
        netifs: ct.netifs,
        interfacesd: Dir.exist?(File.join(base, 'interfaces.d')),
      }

      %i(head tail).each do |v|
        vars[v] = File.exist?(File.join(base, "interfaces.#{v}"))
      end

      OsCtld::Template.render_to(
        'dist_config/network/debian/interfaces',
        vars,
        File.join(ct.rootfs, 'etc', 'network', 'interfaces')
      )
    end

    protected
    def includes_hostname?(line, hostname)
      /\s#{Regexp.escape(hostname)}(\s|$)/ =~ line
    end
  end
end
