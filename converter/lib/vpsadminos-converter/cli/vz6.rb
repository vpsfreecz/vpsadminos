require 'ipaddress'

module VpsAdminOS::Converter
  class Cli::Vz6 < Cli::Command
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def export
      require_args!('ctid', 'file')

      if opts[:vpsadmin]
        opts[:zfs] = true
        opts['zfs-dataset'] = "vz/private/#{args[0]}"
        opts['zfs-subdir'] = 'private'
        opts['netif-type'] = 'routed'
        opts['netif-name'] = 'eth0'
      end

      if opts[:zfs] && opts['zfs-subdir'] != 'private'
        # TODO
        fail "unsupported configuration, only '--zfs-subdir private' is implemented"
      end

      vz_ct = Vz6::Container.new(args[0])
      fail 'container not found' unless vz_ct.exist?

      begin
        puts 'Parsing config'
        vz_ct.load

      rescue RuntimeError => e
        warn "unable to parse config: #{e.message}"
      end

      target_ct = vz_ct.convert(
        User.default,
        Group.default,
        netif: {
          type: opts['netif-type'].to_sym,
          name: opts['netif-name'],
          hwaddr: opts['netif-hwaddr'],
          link: opts['bridge-link'],
          via: parse_route_via(opts['route-via']),
        }
      )
      target_ct.dataset = OsCtl::Lib::Zfs::Dataset.new(
        opts['zfs-dataset'],
        base: opts['zfs-dataset']
      )

      File.open(args[1], 'w') do |f|
        exporter = exporter_class.new(
          target_ct,
          f,
          compression: opts[:compression].to_sym,
          compressed_send: opts['zfs-compressed-send']
        )

        puts 'Exporting metadata'
        exporter.dump_metadata('full')

        puts 'Exporting configs'
        exporter.dump_configs

        puts 'Exporting rootfs'

        if opts[:zfs]
          export_streams(vz_ct, exporter)

        else
          export_tar(vz_ct, exporter)
        end
      end

      puts 'Export done'
      puts
      puts 'Consumed config items:'
      vz_ct.config.each do |it|
        next unless it.consumed?
        puts "  #{it.key} = #{it.value.inspect}"
      end
      puts
      puts 'Ignored config items:'
      vz_ct.config.each do |it|
        next if it.consumed?
        puts "  #{it.key} = #{it.value.inspect}"
      end

    rescue RouteViaMissing => e
      raise GLI::BadCommandLine, "provide --route-via for IPv#{e.ip_v}"
    end

    protected
    def exporter_class
      opts[:zfs] ? Exporter::Zfs : Exporter::Tar
    end

    def export_streams(vz_ct, exporter)
      exporter.dump_rootfs do
        puts '> base stream'
        exporter.dump_base

        if vz_ct.state == :running && opts[:consistent]
          puts '> stopping container'
          syscmd("vzctl stop #{vz_ct.ctid}")

          puts '> incremental stream'
          exporter.dump_incremental

          puts '> restarting container'
          syscmd("vzctl start #{vz_ct.ctid}")
        end
      end
    end

    def export_tar(vz_ct, exporter)
      running = vz_ct.state == :running && opts[:consistent]

      if running
        puts '> stopping container'
        syscmd("vzctl stop #{vz_ct.ctid}")
      end

      puts '> packing rootfs'
      exporter.pack_rootfs

    ensure
      if running
        puts '> restarting container'
        syscmd("vzctl start #{vz_ct.ctid}")
      end
    end

    def parse_route_via(list)
      ret = {}

      list.each do |net|
        addr = IPAddress.parse(net)
        ip_v = addr.ipv4? ? 4 : 6

        if ret.has_key?(ip_v)
          raise GLI::BadCommandLine,
                "network for IPv#{ip_v} has already been set to route via #{ret[ip_v]}"
        end

        case ip_v
        when 4
          if addr.prefix > 30
            raise GLI::BadCommandLine, 'cannot route via IPv4 network smaller than /30'
          end

        when 6
          # TODO: check?
        end

        ret[ip_v] = addr
      end

      ret
    end
  end
end
