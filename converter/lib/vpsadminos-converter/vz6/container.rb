require 'libosctl'

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

    def status
      stats = syscmd("vzctl status #{ctid}")[:output].strip.split(' ')

      {
        exist: stats[2] == 'exist',
        mounted: stats[3] == 'mounted',
        running: stats[4] == 'running',
      }
    end

    def running?
      status[:running]
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
        'VE_PRIVATE',
        'VE_LAYOUT', # TODO: check?
        'NETFILTER',
      ].each { |v| config.consume(v) }

      if ploop?
        ct.rootfs = config.consume('VE_ROOT')
      else
        ct.rootfs = config.consume('VE_PRIVATE')
      end

      fail 'config missing OSTEMPLATE' unless config['OSTEMPLATE']
      # TODO: we should probably guarantee distribution names and allowed version
      #       specification... e.g. allow debian-9.0, forbid debian-stretch
      ct.distribution, ct.version = config.consume('OSTEMPLATE').split('-')

      ct.hostname = config.consume('HOSTNAME') || 'vps'

      if config['NAMESERVER']
        ct.dns_resolvers.concat(config.consume('NAMESERVER').map(&:to_s))
      end

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
          netif.routes = {4 => [], 6 => []}
        end

        all_ips = config.consume('IP_ADDRESS')

        [4, 6].each do |ip_v|
          netif.ip_addresses[ip_v] = all_ips.select do |ip|
            ip.send("ipv#{ip_v}?")
          end

          netif.routes[ip_v] = netif.ip_addresses[ip_v] if netif.type == :routed
        end

        ct.netifs << netif
      end

      if config['DEVICES']
        config.consume('DEVICES').each do |dev|
          ct.devices << dev.to_ct_device
        end
      end

      ct
    end

    def layout
      fail 'unable to determine VE_LAYOUT' unless config['VE_LAYOUT']
      config['VE_LAYOUT'].value
    end

    def ploop?
      layout.start_with?('ploop')
    end
  end
end
