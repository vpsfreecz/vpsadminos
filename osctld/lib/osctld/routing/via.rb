module OsCtld
  class Routing::Via
    attr_reader :net_addr, :host_addr, :ct_addr

    alias_method :host_ip, :host_addr
    alias_method :ct_ip, :ct_addr

    # Load from config
    def self.load(cfg)
      if cfg.is_a?(String) # for backward compatibility
        net_addr = IPAddress.parse(cfg)

      else
        net_addr = IPAddress.parse(cfg['network'])
      end

      self.for(net_addr).new(
        net_addr,
        cfg.is_a?(Hash) && IPAddress.parse(cfg['host']),
        cfg.is_a?(Hash) && IPAddress.parse(cfg['ct']),
      )
    end

    def self.for(net_addr)
      if net_addr.ipv4?
        Routing::ViaIPv4

      else
        Routing::ViaIPv6
      end
    end

    def initialize(net_addr, host_addr, ct_addr)
      @net_addr = net_addr

      uint = addr_to_uint(net_addr)
      @host_addr = host_addr || get_host_addr(uint)
      @ct_addr = ct_addr || get_ct_addr(uint)

      if @host_addr == @ct_addr
        fail "host_addr cannot equal ct_addr: #{@host_addr.to_string}"
      end
    end

    def version
      net_addr.ipv4? ? 4 : 6
    end

    # Dump to config
    def dump
      {
        'network' => net_addr.to_string,
        'host' => host_addr.to_string,
        'ct' => ct_addr.to_string,
      }
    end

    protected
    def get_host_addr(net_uint)
      addr = uint_to_addr(net_uint + 1)
      addr.prefix = net_addr.prefix.to_i
      addr
    end

    def get_ct_addr(net_uint)
      addr = uint_to_addr(net_uint + 2)
      addr.prefix = net_addr.prefix.to_i
      addr
    end

    def uint_to_addr
      raise NotImplementedError
    end

    def addr_to_uint
      raise NotImplementedError
    end
  end
end
