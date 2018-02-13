module VpsAdminOS::Converter
  # Instances represent OpenVZ Legacy containers
  class Vz6::Container
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    attr_reader :ctid, :config

    def initialize(ctid)
      @ctid = ctid
    end

    def exist?
      ret = syscmd("vzlist #{ctid}", valid_rcs: [1])
      ret[:exitstatus] == 0
    end

    def state
      syscmd("vzctl status #{ctid}")[:output].strip.split(' ')[4].to_sym
    end

    # Load config from `/etc/vz/conf/%{ctid}.conf`
    def load
      @config = Vz6::Config.parse(ctid, "/etc/vz/conf/#{ctid}.conf")
    end

    # @param user [User]
    # @param group [Group]
    # @param opts [Hash]
    # @option opts [Hash] :netif
    # @return [Container]
    def convert(user, group, opts = {})
      ct = Container.new(ctid, user, group)

      [
        'VE_ROOT',
        'VE_LAYOUT', # TODO: check?
        'NETFILTER',
      ].each { |v| config.consume(v) }

      ct.rootfs = config.consume('VE_PRIVATE')

      fail 'config missing OSTEMPLATE' unless config['OSTEMPLATE']
      # TODO: we should probably guarantee distribution names and allowed version
      #       specification... e.g. allow debian-9.0, forbid debian-stretch
      ct.distribution, ct.version = config.consume('OSTEMPLATE').split('-')

      ct.hostname = config.consume('HOSTNAME')
      ct.dns_resolvers.concat(config.consume('NAMESERVER').map(&:to_s))

      ct.autostart.enabled = true if config.consume('ONBOOT')

      if config['PHYSPAGES']
        mem = config.consume('PHYSPAGES')[1] * 4 * 1024

        if config['SWAPPAGES']
          ct.cgparams.set(
            'memory.memsw.limit_in_bytes',
            mem + config.consume('SWAPPAGES')[1] * 4 * 1024
          )
        end

        ct.cgparams.set('memory.limit_in_bytes', mem)
      end

      if config['IP_ADDRESS'] && opts[:netif]
        netif = NetInterface.for(opts[:netif][:type]).new(
          opts[:netif][:name],
          opts[:netif][:hwaddr]
        )

        case netif.type
        when :bridge
          netif.link = opts[:netif][:link]

        when :routed
          netif.via = opts[:netif][:via]
        end

        all_ips = config.consume('IP_ADDRESS')

        [4, 6].each do |ip_v|
          netif.ip_addresses[ip_v] = all_ips.select do |ip|
            ip.send("ipv#{ip_v}?")
          end

          if netif.type == :routed && netif.ip_addresses[ip_v].any? && !netif.via[ip_v]
            raise RouteViaMissing, ip_v
          end
        end

        ct.netifs << netif
      end

      ct
    end
  end
end
