require 'vpsadminos-converter/cli/command'

module VpsAdminOS::Converter
  class Cli::Vz6::Base < Cli::Command
    protected
    def convert_ct(ctid)
      if opts[:vpsadmin]
        opts[:zfs] = true
        opts['zfs-dataset'] = "vz/private/#{ctid}"
        opts['zfs-subdir'] = 'private'
        opts['netif-type'] = 'routed'
        opts['netif-name'] = 'eth0'
      end

      if opts[:zfs] && opts['zfs-subdir'] != 'private'
        # TODO
        fail "unsupported configuration, only '--zfs-subdir private' is implemented"
      end

      vz_ct = Vz6::Container.new(ctid)
      fail 'container not found' unless vz_ct.exist?

      begin
        puts 'Parsing config'
        vz_ct.load

      rescue RuntimeError => e
        fail "unable to parse config: #{e.message}"
      end

      if opts[:zfs] && vz_ct.ploop?
        fail "container uses ploop, but ZFS was enabled"
      end

      target_ct = vz_ct.convert(
        User.default,
        Group.default,
        netif: {
          type: opts['netif-type'].to_sym,
          name: opts['netif-name'],
          hwaddr: opts['netif-hwaddr'],
          link: opts['bridge-link'],
        }
      )

      if opts[:zfs]
        target_ct.dataset = OsCtl::Lib::Zfs::Dataset.new(
          opts['zfs-dataset'],
          base: opts['zfs-dataset']
        )
      end

      [vz_ct, target_ct]
    end

    def print_convert_status(vz_ct)
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

    def exporter_class
      opts[:zfs] ? Exporter::Zfs : Exporter::Tar
    end
  end
end
