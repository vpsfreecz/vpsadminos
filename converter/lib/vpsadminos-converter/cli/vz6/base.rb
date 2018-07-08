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
          via: parse_route_via(opts['route-via']),
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

    def parse_route_via(list)
      ret = {}

      host_addrs = opts['route-host-addr'].map { |v| IPAddress.parse(v) }
      ct_addrs = opts['route-ct-addr'].map { |v| IPAddress.parse(v) }

      list.each do |addr|
        network = IPAddress.parse(addr)
        ip_v = network.ipv4? ? 4 : 6

        if ret.has_key?(ip_v)
          raise GLI::BadCommandLine,
                "network for IPv#{ip_v} has already been set to route via #{ret[ip_v]}"
        end

        case ip_v
        when 4
          if network.prefix > 30
            raise GLI::BadCommandLine, 'cannot route via IPv4 network smaller than /30'
          end

        when 6
          if network.prefix > 126
            raise GLI::BadCommandLine, "cannot route via IPv6 network smaller than /126"
          end
        end

        host_addr = get_net_addr(network, host_addrs, 'host')
        ct_addr = get_net_addr(network, ct_addrs, 'container')

        if (host_addr && !ct_addr) || (!host_addr && ct_addr)
          raise GLI::BadCommandLine, 'provide both host and container address'

        elsif host_addr && host_addr == ct_addr
          raise GLI::BadCommandLine, 'use different addresses for host and container'
        end

        ret[ip_v] = {
          network: network,
          host: host_addr,
          ct: ct_addr,
        }
      end

      ret
    end

    def get_net_addr(network, list, type)
      addr = list.detect { |v| v.class == network.class }
      return addr if addr.nil? || network.include?(addr)

      raise GLI::BadCommandLine, "network #{network.to_string} does not "+
                                 "include #{type} address #{addr.to_string}"
    end
  end
end
