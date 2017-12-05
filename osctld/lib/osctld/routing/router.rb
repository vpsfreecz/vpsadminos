require 'ipaddress'

module OsCtld
  class Routing::Router
    include Utils::Log
    include Utils::System
    include Utils::Ip

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
      @allocations = {}
    end

    public
    def setup_veth(ct, ip_v)
      sync do
        allocation = via(ct.route_via(ip_v))

        @allocations[ct.id] ||= {}
        @allocations[ct.id][ip_v] = allocation

        ip(ip_v, :addr, :add, allocation.host_ip.to_string, :dev, ct.veth)
        true
      end
    end

    def free_veth(ct)
      sync do
        next(true) unless @allocations.has_key?(ct.id)

        @allocations.delete(ct.id)
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
    def via(addr_str)
      addr = IPAddress.parse(addr_str)

      if addr.ipv4?
        Routing::ViaIPv4.new(addr)

      else
        Routing::ViaIPv6.new(addr)
      end
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
