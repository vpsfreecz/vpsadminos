require 'ipaddress'

module OsCtld
  # Represents routing table for a network interface
  class Routing::Table
    # Routing table for specific IP version
    class Version
      include Lockable

      # @param cfg [Array<String>]
      def self.load(cfg)
        new(addrs: cfg.map { |addr| IPAddress.parse(addr) })
      end

      def initialize(addrs: nil)
        @routes = addrs || []
        init_lock
      end

      # @param addr [IPAddress::IPv4, IPAddress::IPv6]
      def <<(addr)
        exclusively { routes << addr }
      end

      # @param addr [IPAddress::IPv4, IPAddress::IPv6]
      # @return [IPAddress::IPv4, IPAddress::IPv6, nil]
      def remove(addr)
        exclusively { routes.delete(addr) }
      end

      # @param addr [IPAddress::IPv4, IPAddress::IPv6]
      def route?(addr)
        ret = exclusively do
          routes.detect do |r|
            r == addr || (r.network? && r.include?(addr))
          end
        end

        ret ? true : false
      end

      # @param addr [IPAddress::IPv4, IPAddress::IPv6]
      def contains?(addr)
        exclusively do
          routes.detect { |r| r == addr } ? true : false
        end
      end

      def empty?
        exclusively { routes.empty? }
      end

      def any?
        !empty?
      end

      def clear
        exclusively { routes.clear }
      end

      # Get all routed addresses
      # @return [Array]
      def get
        exclusively { routes.clone }
      end

      # @return [Array<String>]
      def export
        exclusively { routes.map(&:to_string) }
      end

      # @return [Array<String>]
      def dump
        export
      end

      protected
      attr_reader :routes
    end

    # Load the table from config
    # @param cfg [Hash]
    def self.load(cfg)
      new(tables: {
        4 => (cfg['v4'] && Version.load(cfg['v4'])) || Version.new,
        6 => (cfg['v6'] && Version.load(cfg['v6'])) || Version.new,
      })
    end

    def initialize(tables: nil)
      @tables = tables || {4 => Version.new, 6 => Version.new}
    end

    # @param addr [IPAddress::IPv4, IPAddress::IPv6]
    def <<(addr)
      t(addr) << addr
    end

    # @param addr [IPAddress::IPv4, IPAddress::IPv6]
    # @return [IPAddress::IPv4, IPAddress::IPv6, nil]
    def remove(addr)
      t(addr).remove(addr)
    end

    # @param ip_v [Integer, nil]
    # @return [Array<IPAddress::IPv4, IPAddress::IPv6>]
    def remove_all(ip_v = nil)
      ret = []

      (ip_v ? [ip_v] : [4, 6]).each do |v|
        ret.concat(tables[v].get)
        tables[v].clear
      end

      ret
    end

    # Check if the table routes `addr`
    # @param addr [IPAddress::IPv4, IPAddress::IPv6]
    def route?(addr)
      t(addr).route?(addr)
    end

    # Check if there is an exact entry for `addr`
    # @param addr [IPAddress::IPv4, IPAddress::IPv6]
    def contains?(addr)
      t(addr).contains?(addr)
    end

    # Check if there are any routes for given IP version
    # @param v [Integer] IP version
    def any?(v)
      tables[v].any?
    end

    # @param v [Integer] IP version
    def empty?(v)
      tables[v].empty?
    end

    # Iterate over all routes
    # @yieldparam version [Integer] IP version
    # @yieldparam addr [IPAddress::IPv4, IPAddress::IPV6]
    def each(ip_v, &block)
      ret = []

      tables.each do |version, table|
        ret.concat(table.get.map { |addr| [version, addr] })
      end

      Hash[ret].each(&block)
    end

    # Iterate over all routes for IP version
    # @param ip_v [Integer]
    def each_version(ip_v, &block)
      tables[ip_v].get.each(&block)
    end

    # Export the table to clients
    # @return [Hash]
    def export
      Hash[ tables.map { |version, table| [version, table.export] } ]
    end

    # Dump the table into config
    # @return [Hash]
    def dump
      Hash[ tables.map { |version, table| ["v#{version}", table.dump] } ]
    end

    protected
    attr_reader :tables

    def t(addr)
      addr.ipv4? ? tables[4] : tables[6]
    end
  end
end
