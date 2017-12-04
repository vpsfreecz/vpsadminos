module OsCtld
  class Routing::IPv6Subnet < Routing::Subnet
    bits 128
    split_prefix 64

    protected
    def each_network
      range = (net_addr.network_u128 .. net_addr.broadcast_u128)
      range.step(2**(self.class.bits - self.class.split_prefix)).each do |i|
        yield(i)
      end
    end

    def uint_to_addr(uint)
      IPAddress::IPv6.parse_u128(uint)
    end

    def addr_to_uint(addr)
      addr.network_u128
    end
  end
end

