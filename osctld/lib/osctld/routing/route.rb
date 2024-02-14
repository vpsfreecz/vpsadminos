require 'ipaddress'

module OsCtld
  # Represents one route from a routing table
  class Routing::Route
    # Load route from config
    def self.load(cfg)
      if cfg.is_a?(Hash)
        new(
          IPAddress.parse(cfg['address']),
          via: cfg['via'] && IPAddress.parse(cfg['via'])
        )
      else
        new(IPAddress.parse(cfg))
      end
    end

    # @return [IPAddress::IPv4, IPAddress::IPv6]
    attr_reader :addr

    # @return [IPAddress::IPv4, IPAddress::IPv6, nil]
    attr_reader :via

    # @return [Integer]
    attr_reader :ip_version

    # Arguments for `ip` that identify the route
    # @return [Array]
    attr_reader :ip_spec

    def initialize(addr, via: nil)
      @addr = addr
      @via = via
      @ip_version = addr.ipv4? ? 4 : 6
      @ip_spec = [addr.to_string]
      @ip_spec.push('via', via.to_s, 'onlink') if via
    end

    # @param addr [IPAddress::IPv4, IPAddress::IPv6]
    def route?(addr)
      @addr == addr || (@addr.network? && @addr.include?(addr))
    end

    # Dump to config
    def dump
      if via
        { 'address' => addr.to_string, 'via' => via.to_s }
      else
        addr.to_string
      end
    end

    # Export to clients
    def export
      { address: addr, via: }
    end
  end
end
