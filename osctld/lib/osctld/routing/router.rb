require 'ipaddress'

module OsCtld
  class Routing::Router
    include Utils::Log
    include Utils::System
    include Utils::Ip

    SUBNETS = [
      '172.17.98.0/22',
      'fe80:1234:5678::/48',
    ]

    @@instance = nil

    class << self
      def instance
        @@instance = new unless @@instance
        @@instance
      end

      %i(setup_veth free_veth add_ip del_ip).each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    private
    def initialize
      @mutex = Mutex.new
      @subnets = {4 => [], 6 => []}

      SUBNETS.each do |v|
        addr = IPAddress.parse(v)
        s = addr.ipv4? ? Routing::IPv4Subnet.new(addr) : Routing::IPv6Subnet.new(addr)

        @subnets[s.version] << s
      end

      @allocations = {}
    end

    public
    def setup_veth(ct, ip_v)
      sync do
        net = find_free_subnet(ip_v)
        raise "no free subnet found for IPv#{ip_v}" unless net

        allocation = net.allocate

        @allocations[ct.id] ||= {}
        @allocations[ct.id][ip_v] = allocation

        ip(ip_v, :addr, :add, allocation.host_ip.to_string, :dev, ct.veth)

        true
      end
    end

    def free_veth(ct)
      sync do
        next(true) unless @allocations.has_key?(ct.id)

        @allocations[ct.id].each do |ip_v, allocation|
          allocation.release
        end
      end
    end

    def add_ip(ct, addr)
      sync do
        ip_v = addr.ipv4? ? 4 : 6
        setup_veth(ct, ip_v) unless setup?(ct, ip_v)

        allocation = @allocations[ct.id][ip_v]

        ip(
          ip_v,
          :route, :add,
          addr.to_string, :via, allocation.ct_ip.to_s, :dev, ct.veth
        )
      end
    end

    def del_ip(ct, addr)
      sync do
        ip_v = addr.ipv4? ? 4 : 6
        allocation = @allocations[ct.id][ip_v]

        ip(
          ip_v,
          :route, :del,
          addr.to_string, :via, allocation.ct_ip.to_s, :dev, ct.veth
        )
      end
    end

    private
    def find_free_subnet(ip_v)
      @subnets[ip_v].detect { |s| s.free? }
    end

    def setup?(ct, ip_v)
      @allocations.has_key?(ct.id) && @allocations[ct.id].has_key?(ip_v)
    end

    def sync
      if @mutex.owned?
        yield
      else
        @mutex.synchronize { yield }
      end
    end
  end
end
