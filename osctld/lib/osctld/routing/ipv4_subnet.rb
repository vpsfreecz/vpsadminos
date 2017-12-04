module OsCtld
  class Routing::IPv4Subnet < Routing::Subnet
    bits 32
    split_prefix 30

    protected
    def each_network
      range = (net_addr.network_u32 .. net_addr.broadcast_u32)
      range.step(2**(self.class.bits - self.class.split_prefix)).each do |i|
        yield(i)
      end
    end

    def uint_to_addr(uint)
      IPAddress::IPv4.parse_u32(uint)
    end

    def addr_to_uint(addr)
      addr.network_u32
    end
  end
end
