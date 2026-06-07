require 'open3'
require 'test-runner/test_resources'

module TestRunner
  class ResourcePool
    DEFAULT_MEMORY_RESERVE_MIB = 4096
    DEFAULT_SHM_RESERVE_MIB = 4096

    # @return [Integer, nil]
    attr_reader :memory_mib

    # @return [Integer, nil]
    attr_reader :shm_mib

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

      new(
        memory_mib: capacity(
          integer_option(opts[:max_memory_mib], env['TEST_RUNNER_MAX_MEMORY_MIB'], nil) ||
            detect_memory_available_mib,
          memory_reserve_mib
        ),
        shm_mib: capacity(
          integer_option(opts[:max_shm_mib], env['TEST_RUNNER_MAX_SHM_MIB'], nil) ||
            detect_shm_available_mib,
          shm_reserve_mib
        )
      )
    end

    def self.integer_option(*values)
      value = values.detect { |v| !v.nil? && v.to_s != '' }
      return nil if value.nil?

      Integer(value)
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

    def initialize(memory_mib:, shm_mib:)
      @memory_mib = memory_mib
      @shm_mib = shm_mib
      @used = TestResources.new
      @running = 0
    end

    def can_reserve?(resources)
      fits?(memory_mib, used.memory_mib + resources.memory_mib) &&
        fits?(shm_mib, used.shm_mib + resources.shm_mib)
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
        "shm=#{format_used(shm_mib, used.shm_mib)}, running=#{running}"
    end

    protected

    def fits?(capacity, value)
      capacity.nil? || value <= capacity
    end

    def format_used(capacity, value)
      return "#{format_mib(value)}/unlimited" if capacity.nil?

      "#{format_mib(value)}/#{format_mib(capacity)}"
    end

    def format_mib(value)
      return "#{value} MiB" if value < 1024

      format('%.1f GiB', value / 1024.0)
    end
  end
end
