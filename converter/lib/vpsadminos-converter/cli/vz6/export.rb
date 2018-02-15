require 'ipaddress'

module VpsAdminOS::Converter
  class Cli::Vz6::Export < Cli::Vz6::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def export
      require_args!('ctid', 'file')

      vz_ct, target_ct = convert_ct(args[0])

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

        elsif vz_ct.ploop?
          export_tar_ploop(vz_ct, exporter)

        else
          export_tar_simfs(vz_ct, exporter)
        end
      end

      puts 'Export done'
      puts
      print_convert_status(vz_ct)

    rescue RouteViaMissing => e
      raise GLI::BadCommandLine, "provide --route-via for IPv#{e.ip_v}"
    end

    protected
    def export_streams(vz_ct, exporter)
      exporter.dump_rootfs do
        puts '> base stream'
        exporter.dump_base

        if vz_ct.running? && opts[:consistent]
          puts '> stopping container'
          syscmd("vzctl stop #{vz_ct.ctid}")

          puts '> incremental stream'
          exporter.dump_incremental

          puts '> restarting container'
          syscmd("vzctl start #{vz_ct.ctid}")
        end
      end
    end

    def export_tar_ploop(vz_ct, exporter)
      status = vz_ct.status

      if status[:running] && opts[:consistent]
        puts '> stopping container'
        syscmd("vzctl stop #{vz_ct.ctid}")
        syscmd("vzctl mount #{vz_ct.ctid}")

      elsif !status[:mounted]
        syscmd("vzctl mount #{vz_ct.ctid}")
      end

      puts '> packing rootfs'
      exporter.pack_rootfs

    ensure
      if status[:running] && opts[:consistent]
        puts '> restarting container'
        syscmd("vzctl start #{vz_ct.ctid}")

      elsif !status[:mounted]
        syscmd("vzctl umount #{vz_ct.ctid}")
      end
    end

    def export_tar_simfs(vz_ct, exporter)
      running = vz_ct.running? && opts[:consistent]

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
  end
end
