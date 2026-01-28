require 'securerandom'
require 'singleton'

module OsVm
  class MacAddressGenerator
    include Singleton

    PREFIX = '52:54:00'.freeze

    def initialize
      @registry = Set.new
      @mutex = Mutex.new
    end

    # Generate and register a unique MAC address
    # @return [String]
    def next_mac
      synchronize do
        loop do
          mac = random_mac
          next if @registry.include?(mac)

          @registry << mac
          return mac
        end
      end
    end

    # Register an externally provided MAC address
    # @param mac [String]
    # @return [String]
    def register_mac(mac)
      synchronize do
        if @registry.include?(mac)
          raise ArgumentError, "duplicate MAC address #{mac.inspect}"
        end

        @registry << mac
        mac
      end
    end

    private

    def random_mac
      suffix = SecureRandom.hex(3).scan(/../).join(':')
      "#{PREFIX}:#{suffix}"
    end

    def synchronize(&)
      @mutex.synchronize(&)
    end

    class << self
      # @return [String]
      def next_mac
        instance.next_mac
      end

      # @param mac [String]
      # @return [String]
      def register_mac(mac)
        instance.register_mac(mac)
      end
    end
  end
end
