require 'singleton'
require 'fileutils'

module OsVm
  # Singleton class handling port reservations
  class PortReservation
    include Singleton

    PORT_RANGE = (10_000..30_000)

    class << self
      %i[get_port release_port get_ports release_ports reset_to_ports].each do |v|
        define_method(v) do |*args, **kwargs, &block|
          instance.send(v, *args, **kwargs, &block)
        end
      end
    end

    def initialize
      ports = PORT_RANGE.to_a
      @ports = ports.rotate(rand(ports.length))
      @allocations = {}
      @port_locks = {}
      @scoped = false
      @mutex = Mutex.new
    end

    # @param key [any]
    # @return [Integer]
    def get_port(key:)
      @mutex.synchronize do
        alloc = @allocations[key]
        next(alloc.first) if alloc

        port = allocate_port
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

        ports = []

        begin
          size.times { ports << allocate_port }
        rescue StandardError
          ports.each { |port| release_allocated_port(port) }
          raise
        end

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
        alloc.each { |port| release_allocated_port(port) }
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
        @port_locks.each_value(&:close)
        @ports = ports.dup
        @allocations = {}
        @port_locks = {}
        @scoped = true
      end

      nil
    end

    protected

    def allocate_port
      if @scoped
        port = @ports.shift
        raise 'No ports available for reservation' if port.nil?

        return port
      end

      @ports.each_with_index do |candidate, index|
        lock = acquire_port_lock(candidate)
        next if lock.nil?

        @ports.delete_at(index)
        @port_locks[candidate] = lock
        return candidate
      end

      raise 'No ports available for reservation'
    end

    def release_allocated_port(port)
      @port_locks.delete(port)&.close
      @ports << port
    end

    def acquire_port_lock(port)
      FileUtils.mkdir_p(lock_directory, mode: 0o700)
      lock = File.open(File.join(lock_directory, port.to_s), File::RDWR | File::CREAT, 0o600)

      return lock if lock.flock(File::LOCK_EX | File::LOCK_NB)

      lock.close
      nil
    end

    def lock_directory
      root = ENV.fetch('OSVM_PORT_RESERVATION_ROOT', '/var/tmp')
      File.join(root, "osvm-port-reservations-#{Process.uid}")
    end
  end
end
