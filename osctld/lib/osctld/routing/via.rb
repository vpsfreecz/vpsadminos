module OsCtld
  class Routing::Via
    attr_reader :net_addr, :host_ip, :ct_ip

    def self.for(net_addr)
      if net_addr.ipv4?
        Routing::ViaIPv4.new(net_addr)

      else
        Routing::ViaIPv6.new(net_addr)
      end
    end

    def initialize(net_addr)
      @net_addr = net_addr

      uint = addr_to_uint(net_addr)
      @host_ip = get_host_ip(uint)
      @ct_ip = get_ct_ip(uint)
    end

    def version
      net_addr.ipv4? ? 4 : 6
    end

    protected
    def get_host_ip(net_uint)
      addr = uint_to_addr(net_uint + 1)
      addr.prefix = net_addr.prefix.to_i
      addr
    end

    def get_ct_ip(net_uint)
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
