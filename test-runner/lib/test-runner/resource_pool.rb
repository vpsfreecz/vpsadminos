require 'open3'
require 'test-runner/test_resources'

module TestRunner
  class ResourcePool
    DEFAULT_MEMORY_RESERVE_MIB = 4096
    DEFAULT_SHM_RESERVE_MIB = 4096
    DEFAULT_CPU_RESERVE = 0
    DEFAULT_MEMORY_OVERCOMMIT = 1.0
    DEFAULT_SHM_OVERCOMMIT = 1.0
    DEFAULT_CPU_OVERCOMMIT = 1.5

    class HostResourceDetector
      def memory_available_mib
        ResourcePool.detect_memory_available_mib
      end

      def shm_available_mib
        ResourcePool.detect_shm_available_mib
      end

      def cpus
        ResourcePool.detect_cpus
      end
    end

    class CapacitySource
      def initialize(max_value:, reserve:, detector:, add_used:, overcommit:)
        @max_value = max_value
        @reserve = reserve
        @detector = detector
        @add_used = add_used
        @overcommit = overcommit
      end

      def current(used:)
        detected = @detector.call
        detected += used if detected && @add_used

        ResourcePool.capacity(limit(overcommit(detected)), @reserve)
      end

      protected

      attr_reader :max_value

      def overcommit(detected)
        return nil if detected.nil?

        (detected * @overcommit).floor
      end

      def limit(detected)
        if detected && max_value
          [detected, max_value].min
        elsif detected
          detected
        else
          max_value
        end
      end
    end

    # @return [Integer, nil]
    attr_reader :memory_mib

    # @return [Integer, nil]
    attr_reader :shm_mib

    # @return [Integer, nil]
    attr_reader :cpus

    # @return [TestResources]
    attr_reader :used

    # @return [Integer]
    attr_reader :running

    def self.from_options(opts, env: ENV)
      memory_reserve_mib = integer_option(
        opts[:memory_reserve_mib],
        env['TEST_RUNNER_MEMORY_RESERVE_MIB'],
        DEFAULT_MEMORY_RESERVE_MIB
      )
      shm_reserve_mib = integer_option(
        opts[:shm_reserve_mib],
        env['TEST_RUNNER_SHM_RESERVE_MIB'],
        DEFAULT_SHM_RESERVE_MIB
      )
      cpu_reserve = integer_option(
        opts[:cpu_reserve],
        env['TEST_RUNNER_CPU_RESERVE'],
        DEFAULT_CPU_RESERVE
      )
      memory_overcommit = factor_option(
        opts[:memory_overcommit],
        env['TEST_RUNNER_MEMORY_OVERCOMMIT'],
        DEFAULT_MEMORY_OVERCOMMIT
      )
      shm_overcommit = factor_option(
        opts[:shm_overcommit],
        env['TEST_RUNNER_SHM_OVERCOMMIT'],
        DEFAULT_SHM_OVERCOMMIT
      )
      cpu_overcommit = factor_option(
        opts[:cpu_overcommit],
        env['TEST_RUNNER_CPU_OVERCOMMIT'],
        DEFAULT_CPU_OVERCOMMIT
      )
      detector = opts[:resource_detector] || HostResourceDetector.new

      new(
        memory_mib: nil,
        shm_mib: nil,
        cpus: nil,
        memory_capacity: CapacitySource.new(
          max_value: integer_option(opts[:max_memory_mib], env['TEST_RUNNER_MAX_MEMORY_MIB'], nil),
          reserve: memory_reserve_mib,
          detector: -> { detector.memory_available_mib },
          add_used: true,
          overcommit: memory_overcommit
        ),
        shm_capacity: CapacitySource.new(
          max_value: integer_option(opts[:max_shm_mib], env['TEST_RUNNER_MAX_SHM_MIB'], nil),
          reserve: shm_reserve_mib,
          detector: -> { detector.shm_available_mib },
          add_used: true,
          overcommit: shm_overcommit
        ),
        cpu_capacity: CapacitySource.new(
          max_value: integer_option(opts[:max_cpus], env['TEST_RUNNER_MAX_CPUS'], nil),
          reserve: cpu_reserve,
          detector: -> { detector.cpus },
          add_used: false,
          overcommit: cpu_overcommit
        )
      )
    end

    def self.integer_option(*values)
      value = values.detect { |v| !v.nil? && v.to_s != '' }
      return nil if value.nil?

      Integer(value)
    end

    def self.factor_option(*values)
      value = values.detect { |v| !v.nil? && v.to_s != '' }
      return nil if value.nil?

      ret = Float(value)
      raise ArgumentError, 'overcommit factors must be positive' if ret <= 0

      ret
    end

    def self.capacity(value, reserve)
      return nil if value.nil?

      [value - reserve, 0].max
    end

    def self.detect_memory_available_mib
      return nil unless File.file?('/proc/meminfo')

      line = File.readlines('/proc/meminfo').detect { |v| v.start_with?('MemAvailable:') }
      return nil if line.nil?

      line.split[1].to_i / 1024
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def self.detect_shm_available_mib
      out, status = Open3.capture2('df', '-Pk', '/dev/shm')
      return nil unless status.success?

      line = out.lines[1]
      return nil if line.nil?

      line.split[3].to_i / 1024
    rescue Errno::ENOENT
      nil
    end

    def self.detect_cpus
      out, status = Open3.capture2('nproc')
      return nil unless status.success?

      Integer(out.strip)
    rescue Errno::ENOENT, ArgumentError
      nil
    end

    def initialize(memory_mib:, shm_mib:, cpus:, memory_capacity: nil, shm_capacity: nil, cpu_capacity: nil)
      @memory_capacity = memory_capacity
      @shm_capacity = shm_capacity
      @cpu_capacity = cpu_capacity
      @memory_mib = memory_mib
      @shm_mib = shm_mib
      @cpus = cpus
      @used = TestResources.new
      @running = 0

      refresh_capacity
    end

    def refresh_capacity
      previous = capacities

      @memory_mib = @memory_capacity.current(used: used.memory_mib) if @memory_capacity
      @shm_mib = @shm_capacity.current(used: used.shm_mib) if @shm_capacity
      @cpus = @cpu_capacity.current(used: 0) if @cpu_capacity

      previous != capacities
    end

    def can_reserve?(resources)
      fits?(memory_mib, used.memory_mib + resources.memory_mib) &&
        fits?(shm_mib, used.shm_mib + resources.shm_mib) &&
        fits?(cpus, used.cpus + resources.cpus)
    end

    def reserve(resources)
      @used += resources
      @running += 1
    end

    def release(resources)
      @used -= resources
      @running -= 1
    end

    def status
      "memory=#{format_used(memory_mib, used.memory_mib)}, " \
        "shm=#{format_used(shm_mib, used.shm_mib)}, " \
        "cpus=#{format_used(cpus, used.cpus, unit: false)}, running=#{running}"
    end

    protected

    def capacities
      [memory_mib, shm_mib, cpus]
    end

    def fits?(capacity, value)
      capacity.nil? || value <= capacity
    end

    def format_used(capacity, value, unit: true)
      if capacity.nil?
        formatted = unit ? format_mib(value) : value
        return "#{formatted}/unlimited"
      end

      if unit
        "#{format_mib(value)}/#{format_mib(capacity)}"
      else
        "#{value}/#{capacity}"
      end
    end

    def format_mib(value)
      return "#{value} MiB" if value < 1024

      format('%.1f GiB', value / 1024.0)
    end
  end
end
