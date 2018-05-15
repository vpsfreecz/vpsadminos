require 'osctld/routing/via'

module OsCtld
  class Routing::ViaIPv4 < Routing::Via
    def uint_to_addr(uint)
      IPAddress::IPv4.parse_u32(uint)
    end

    def addr_to_uint(addr)
      addr.network_u32
    end
  end
end
