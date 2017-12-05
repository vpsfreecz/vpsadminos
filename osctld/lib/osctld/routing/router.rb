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

      %i(setup setup_veth free_veth add_ip del_ip).each do |v|
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
    # Read system configuration and load the router's current state
    def setup
      ContainerList.get do |cts|
        cts.each do |ct|
          next unless ct.veth

          iplist = ip(:all, [:addr, :show, :dev, ct.veth], valid_rcs: [1])

          if iplist[:exitstatus] == 1
            log(
              :info,
              :router,
              "Veth '#{ct.veth}' of container '#{ct.id}' no longer exists, "+
              "ignoring"
            )
            ct.veth = nil
            next
          end

          [4, 6].each do |ip_v|
            net = ct.route_via(ip_v)
            next unless net

            alloc = via(net)
            inet = ip_v == 4 ? 'inet' : 'inet6'

            if /#{inet} #{Regexp.escape(alloc.host_ip.to_string)}/ =~ iplist[:output]
              log(
                :info,
                :router,
                "Discovered IPv#{ip_v} veth configuration for CT #{ct.id}"
              )

              @allocations[ct.id] ||= {}
              @allocations[ct.id][ip_v] = alloc
            end
          end
        end
      end
    end

    def setup_veth(ct, ip_v)
      sync do
        allocation = via(ct.route_via(ip_v))

        @allocations[ct.id] ||= {}
        @allocations[ct.id][ip_v] = allocation

        ip(ip_v, [:addr, :add, allocation.host_ip.to_string, :dev, ct.veth])
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

        ip(ip_v, [
          :route, :add,
          addr.to_string, :via, allocation.ct_ip.to_s, :dev, ct.veth
        ])
      end
    end

    def del_ip(ct, addr)
      sync do
        ip_v = addr.ipv4? ? 4 : 6
        allocation = @allocations[ct.id][ip_v]

        ip(ip_v, [
          :route, :del,
          addr.to_string, :via, allocation.ct_ip.to_s, :dev, ct.veth
        ])
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
