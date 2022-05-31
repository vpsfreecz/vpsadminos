require 'ipaddress'
require 'thread'

module OsCtl::Image
  # Allocate unique IP addresses from network
  class IpAllocator
    # @param addr [String] IPv4 network address
    def initialize(addr)
      @available = IPAddress.parse(addr).hosts
      @taken = {}
      @mutex = Mutex.new
    end

    # @return [IPAddress::IPv4]
    def get
      @mutex.synchronize do
        ip = @available.shift
        @taken[ip.u32] = ip
        ip
      end
    end

    # @param ip [IPAddress::IPv4]
    def put(ip)
      @mutex.synchronize do
        unless @taken.has_key?(ip.u32)
          fail ArgumentError, "#{ip} was not allocated"
        end

        @taken.delete(ip.u32)
        @available << ip
        nil
      end
    end
  end
end
