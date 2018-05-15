require 'osctld/routing/via'

module OsCtld
  class Routing::ViaIPv6 < Routing::Via
    def uint_to_addr(uint)
      IPAddress::IPv6.parse_u128(uint)
    end

    def addr_to_uint(addr)
      addr.network_u128
    end
  end
end

