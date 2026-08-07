require 'open3'
require 'test-runner/test_resources'

module TestRunner
  class ResourcePool
    DEFAULT_MEMORY_RESERVE_MIB = 8192
    DEFAULT_SHM_RESERVE_MIB = 8192
    DEFAULT_CPU_RESERVE = 0
    DEFAULT_MEMORY_OVERCOMMIT = 1.0
    DEFAULT_SHM_OVERCOMMIT = 1.0
    DEFAULT_CPU_OVERCOMMIT = 1.5

    class HostResourceDetector
      def memory_mib
        ResourcePool.detect_memory_mib
      end

      def memory_available_mib
        ResourcePool.detect_memory_available_mib
      end

      def shm_mib
        ResourcePool.detect_shm_mib
      end

      def shm_available_mib
        ResourcePool.detect_shm_available_mib
      end

      def cpus
        ResourcePool.detect_cpus
      end
    end

    class CapacitySource
      attr_reader :detected, :initial_available, :reserve, :current_value

      def initialize(
        max_value:,
        reserve:,
        detector:,
        overcommit:,
        available_detector: nil,
        monotonic: false
      )
        @max_value = max_value
        @reserve = reserve
        @detector = detector
        @overcommit = overcommit
        @initial_available = available_detector&.call
        @monotonic = monotonic
        @initialized = false
        @current_value = nil
      end

      def current
        @detected = @detector.call
        value = ResourcePool.capacity(limit(overcommit(usable_detected)), reserve)

        if @monotonic && @initialized
          value = monotonic_value(value)
        end

        @initialized = true
        @current_value = value
      end

      protected

      attr_reader :max_value

      def usable_detected
        if detected && initial_available
          [detected, initial_available].min
        else
          detected || initial_available
        end
      end

      def monotonic_value(value)
        return current_value if value.nil?
        return value if current_value.nil?

        [current_value, value].min
      end

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
          detector: -> { detector_value(detector, :memory_mib) },
          available_detector: -> { detector_value(detector, :memory_available_mib) },
          overcommit: memory_overcommit,
          monotonic: true
        ),
        shm_capacity: CapacitySource.new(
          max_value: integer_option(opts[:max_shm_mib], env['TEST_RUNNER_MAX_SHM_MIB'], nil),
          reserve: shm_reserve_mib,
          detector: -> { detector_value(detector, :shm_mib) },
          available_detector: -> { detector_value(detector, :shm_available_mib) },
          overcommit: shm_overcommit,
          monotonic: true
        ),
        cpu_capacity: CapacitySource.new(
          max_value: integer_option(opts[:max_cpus], env['TEST_RUNNER_MAX_CPUS'], nil),
          reserve: cpu_reserve,
          detector: -> { detector.cpus },
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

    def self.detector_value(detector, *methods)
      method = methods.detect { |m| detector.respond_to?(m) }
      return nil if method.nil?

      detector.public_send(method)
    end

    def self.detect_memory_mib
      mem_total = detect_meminfo_mib('MemTotal:')
      cgroup_limit = detect_cgroup_memory_limit_mib

      if mem_total && cgroup_limit
        [mem_total, cgroup_limit].min
      else
        cgroup_limit || mem_total
      end
    end

    def self.detect_memory_available_mib
      host_available = detect_meminfo_mib('MemAvailable:')
      cgroup_available = detect_cgroup_memory_available_mib

      [host_available, cgroup_available].compact.min
    end

    def self.detect_meminfo_mib(key)
      return nil unless File.file?('/proc/meminfo')

      line = File.readlines('/proc/meminfo').detect { |v| v.start_with?(key) }
      return nil if line.nil?

      line.split[1].to_i / 1024
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def self.detect_cgroup_memory_limit_mib
      detect_cgroup_v2_memory_limit_mib || detect_cgroup_v1_memory_limit_mib
    end

    def self.detect_cgroup_memory_available_mib
      detect_cgroup_v2_memory_available_mib || detect_cgroup_v1_memory_available_mib
    end

    def self.detect_cgroup_v2_memory_limit_mib
      path = current_cgroup_path(nil)
      return nil if path.nil?

      limits = cgroup_path_ancestors(path).filter_map do |ancestor|
        detect_cgroup_memory_limit_file(
          File.join('/sys/fs/cgroup', ancestor, 'memory.max')
        )
      end

      limits.min
    end

    def self.detect_cgroup_v2_memory_available_mib
      path = current_cgroup_path(nil)
      return nil if path.nil?

      headrooms = cgroup_path_ancestors(path).filter_map do |ancestor|
        base = File.join('/sys/fs/cgroup', ancestor)
        limit = detect_cgroup_memory_limit_file(File.join(base, 'memory.max'))
        next if limit.nil?

        usage = detect_cgroup_memory_usage_file(File.join(base, 'memory.current'))
        next if usage.nil?

        [limit - usage, 0].max
      end

      headrooms.min
    end

    def self.detect_cgroup_v1_memory_limit_mib
      path = current_cgroup_path('memory')
      return nil if path.nil?

      detect_cgroup_memory_limit_file(
        File.join('/sys/fs/cgroup/memory', path.sub(%r{\A/}, ''), 'memory.limit_in_bytes')
      )
    end

    def self.detect_cgroup_v1_memory_available_mib
      path = current_cgroup_path('memory')
      return nil if path.nil?

      headrooms = cgroup_path_ancestors(path).filter_map do |ancestor|
        base = File.join('/sys/fs/cgroup/memory', ancestor)
        limit = detect_cgroup_memory_limit_file(File.join(base, 'memory.limit_in_bytes'))
        next if limit.nil?

        usage = detect_cgroup_memory_usage_file(File.join(base, 'memory.usage_in_bytes'))
        next if usage.nil?

        [limit - usage, 0].max
      end

      headrooms.min
    end

    def self.current_cgroup_path(controller)
      return nil unless File.file?('/proc/self/cgroup')

      File.readlines('/proc/self/cgroup').each do |line|
        _id, controllers, path = line.strip.split(':', 3)
        next if path.nil?

        if controller.nil?
          return path if controllers == ''
        elsif controllers.split(',').include?(controller)
          return path
        end
      end

      nil
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def self.cgroup_path_ancestors(path)
      ret = []
      relative_path = path.sub(%r{\A/}, '')

      loop do
        ret << relative_path
        break if relative_path == ''

        relative_path = File.dirname(relative_path)
        relative_path = '' if relative_path == '.'
      end

      ret
    end

    def self.detect_cgroup_memory_limit_file(path)
      return nil unless File.file?(path)

      value = File.read(path).strip
      return nil if ['', 'max'].include?(value)

      bytes = Integer(value)
      return nil if bytes <= 0

      bytes / 1024 / 1024
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      nil
    end

    def self.detect_cgroup_memory_usage_file(path)
      return nil unless File.file?(path)

      bytes = Integer(File.read(path).strip)
      return nil if bytes < 0

      bytes / 1024 / 1024
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      nil
    end

    def self.detect_shm_mib
      detect_df_mib('/dev/shm', 1)
    end

    def self.detect_shm_available_mib
      detect_df_mib('/dev/shm', 3)
    end

    def self.detect_df_mib(path, column)
      out, status = Open3.capture2('df', '-Pk', path)
      return nil unless status.success?

      line = out.lines[1]
      return nil if line.nil?

      line.split[column].to_i / 1024
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

      @memory_mib = @memory_capacity.current if @memory_capacity
      @shm_mib = @shm_capacity.current if @shm_capacity
      @cpus = @cpu_capacity.current if @cpu_capacity

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

    def capacity_status
      [
        format_capacity_source('memory', @memory_capacity),
        format_capacity_source('shm', @shm_capacity)
      ].join('; ')
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

    def format_capacity_source(name, source)
      "#{name} assigned=#{format_optional_mib(source.detected)}, " \
        "available-at-start=#{format_optional_mib(source.initial_available)}, " \
        "reserve=#{format_mib(source.reserve)}, " \
        "limit=#{format_optional_mib(source.current_value)}"
    end

    def format_optional_mib(value)
      value.nil? ? 'unknown' : format_mib(value)
    end
  end
end
