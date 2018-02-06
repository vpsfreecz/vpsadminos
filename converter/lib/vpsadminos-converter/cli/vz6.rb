module VpsAdminOS::Converter
  class Cli::Vz6 < Cli::Command
    include Utils::System

    def export
      require_args!('ctid', 'file')

      if opts[:vpsadmin]
        opts[:zfs] = true
        opts['zfs-dataset'] = "vz/private/#{args[0]}"
        opts['zfs-subdir'] = 'private'
      end

      if !opts[:zfs] || opts['zfs-subdir'] != 'private'
        # TODO
        fail "unsupported configuration, only '--zfs --zfs-subdir private' is implemented"
      end

      vz_ct = Vz6::Container.new(args[0])
      fail 'container not found' unless vz_ct.exist?

      begin
        puts 'Parsing config'
        vz_ct.load

      rescue RuntimeError => e
        warn "unable to parse config: #{e.message}"
      end

      target_ct = vz_ct.convert(User.default, Group.default)
      target_ct.dataset = opts['zfs-dataset']

      File.open(args[1], 'w') do |f|
        exporter = Exporter.new(
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
        exporter.dump_rootfs_stream do
          puts '> base stream'
          exporter.dump_base_stream

          if vz_ct.state == :running && opts[:consistent]
            puts '> stopping container'
            syscmd("vzctl stop #{vz_ct.ctid}")

            puts '> incremental stream'
            exporter.dump_incremental_stream

            puts '> restarting container'
            syscmd("vzctl start #{vz_ct.ctid}")
          end
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
    end
  end
end
