require 'singleton'

module OsVm
  # Singleton class handling port reservations
  class PortReservation
    include Singleton

    class << self

      %i[get_port release_port get_ports release_ports reset_to_ports].each do |v|
        define_method(v) do |*args, **kwargs, &block|
          instance.send(v, *args, **kwargs, &block)
        end
      end
    end

    def initialize
      @ports = (10_000..30_000).to_a
      @allocations = {}
      @mutex = Mutex.new
    end

    # @param key [any]
    # @return [Integer]
    def get_port(key:)
      @mutex.synchronize do
        alloc = @allocations[key]
        next(alloc.first) if alloc

        port = @ports.shift
        @allocations[key] = [port]
        port
      end
    end

    # @param key [any]
    # @param port [Integer]
    def release_port(key:)
      release_ports(key:)
    end

    # @param key [any]
    # @param size [Integer] number of ports
    # @return [Array<Integer>]
    def get_ports(key:, size:)
      @mutex.synchronize do
        alloc = @allocations[key]
        next(alloc) if alloc

        ports = size.times.map { @ports.shift }
        @allocations[key] = ports
        ports
      end
    end

    # @param key [any]
    def release_ports(key:)
      @mutex.synchronize do
        alloc = @allocations[key]
        next if alloc.nil?

        @allocations.delete(key)
        alloc.each { |port| @ports << port }
      end

      nil
    end

    # Reset this class and scope available ports to `ports`
    #
    # This is useful when forking processes: the parent process calls {#get_ports},
    # forks and the child process can be scoped to the reservation using this method.
    #
    # @param ports [Array<Integer>]
    def reset_to_ports(ports)
      @mutex.synchronize do
        @ports = ports
        @allocations = {}
      end

      nil
    end
  end
end
