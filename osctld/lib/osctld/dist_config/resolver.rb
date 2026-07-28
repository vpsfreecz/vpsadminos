require 'ipaddr'

module OsCtld
  module DistConfig::Resolver
    MAX_PAYLOAD_BYTES = 4096
    ADDRESS_RE = /\A[0-9A-Fa-f:.]+\z/

    class Invalid < ArgumentError; end

    def self.render(resolvers)
      unless resolvers.is_a?(Array) && !resolvers.empty?
        raise Invalid, 'at least one DNS resolver is required'
      end

      addresses = resolvers.map do |resolver|
        validate_address(resolver)
      end

      payload = addresses.map { |address| "nameserver #{address}\n" }.join
      payload << "options edns0\n"

      if payload.bytesize > MAX_PAYLOAD_BYTES
        raise Invalid, "DNS resolver payload exceeds #{MAX_PAYLOAD_BYTES} bytes"
      end

      payload
    end

    def self.validate_address(resolver)
      unless resolver.is_a?(String) &&
             resolver.ascii_only? &&
             resolver.match?(ADDRESS_RE)
        raise Invalid, "invalid DNS resolver address #{resolver.inspect}"
      end

      IPAddr.new(resolver)
      resolver
    rescue IPAddr::InvalidAddressError
      raise Invalid, "invalid DNS resolver address #{resolver.inspect}"
    end

    private_class_method :validate_address
  end
end
