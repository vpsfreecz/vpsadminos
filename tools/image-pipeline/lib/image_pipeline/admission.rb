$:.unshift(File.expand_path('../../../../test-runner/lib', __dir__))
require_relative '../../../../test-runner/lib/test-runner/resource_pool'

module ImagePipeline
  class Admission
    Sample = Struct.new(:memory_mib, :memory_available_mib, :shm_mib, :shm_available_mib, :cpus, keyword_init: true)
    POLICY_VARIABLES = %w[
      TEST_RUNNER_MAX_MEMORY_MIB TEST_RUNNER_MAX_SHM_MIB TEST_RUNNER_MAX_CPUS
      TEST_RUNNER_MEMORY_RESERVE_MIB TEST_RUNNER_SHM_RESERVE_MIB TEST_RUNNER_CPU_RESERVE
      TEST_RUNNER_MEMORY_OVERCOMMIT TEST_RUNNER_SHM_OVERCOMMIT TEST_RUNNER_CPU_OVERCOMMIT
    ].freeze

    attr_reader :workers, :evidence

    def initialize(config:, item_count:, state_dir:, workers: nil, max_memory_mib: nil, max_cpus: nil,
                   env: ENV, resource_detector: TestRunner::ResourcePool::HostResourceDetector.new)
      requested = workers.nil? || workers == 'auto' ? item_count : positive_integer(workers)
      demand = TestRunner::TestResources.new(
        machines: 1, memory_mib: positive_integer(config.fetch('memory')),
        cpus: positive_integer(config.fetch('cpus'))
      ) # Virtiofs uses one shared-memory backend equal to the VM's RAM.

      # Freeze the existing detector's post-preparation sample for both the real
      # ResourcePool and the receipt. No capacity is invented from optional caps.
      sample = Sample.new(**Sample.members.to_h do |name|
        value = TestRunner::ResourcePool.detector_value(resource_detector, name)
        unless value.is_a?(Integer) && value > 0
          raise ArgumentError, "image admission requires known positive #{name}"
        end

        [name, value]
      end)
      caps = { max_memory_mib: optional_cap(max_memory_mib), max_cpus: optional_cap(max_cpus) }
      pool = TestRunner::ResourcePool.from_options(caps.merge(resource_detector: sample), env:)
      capacities = { memory_mib: pool.memory_mib, shm_mib: pool.shm_mib, cpus: pool.cpus }
      unless capacities.values.all? { |value| value.is_a?(Integer) && value > 0 }
        raise ArgumentError, 'image admission has no finite positive resource capacity after reserves'
      end

      @workers = [positive_integer(item_count), requested,
                  pool.memory_mib / demand.memory_mib, pool.shm_mib / demand.shm_mib,
                  pool.cpus / demand.cpus].min
      raise ArgumentError, 'no image worker fits the available memory, shared memory and CPUs' if @workers < 1

      disk_mib = config.fetch('disks').sum { |disk| disk_size_mib(disk.fetch('size')) }
      free_mib = TestRunner::ResourcePool.detect_df_mib(state_dir, 3)
      unless free_mib.is_a?(Integer) && free_mib > 0 && free_mib >= disk_mib * @workers
        raise ArgumentError, 'image state filesystem lacks known free space for the configured worker disks'
      end

      @evidence = {
        'sample' => sample.to_h, 'capacity' => capacities,
        'policy' => {
          'defaults' => {
            'memory_reserve_mib' => TestRunner::ResourcePool::DEFAULT_MEMORY_RESERVE_MIB,
            'shm_reserve_mib' => TestRunner::ResourcePool::DEFAULT_SHM_RESERVE_MIB,
            'cpu_reserve' => TestRunner::ResourcePool::DEFAULT_CPU_RESERVE,
            'memory_overcommit' => TestRunner::ResourcePool::DEFAULT_MEMORY_OVERCOMMIT,
            'shm_overcommit' => TestRunner::ResourcePool::DEFAULT_SHM_OVERCOMMIT,
            'cpu_overcommit' => TestRunner::ResourcePool::DEFAULT_CPU_OVERCOMMIT
          },
          'environment' => env.to_h.slice(*POLICY_VARIABLES), 'legacy_caps' => caps
        },
        'worker' => { 'memory_mib' => demand.memory_mib, 'shm_mib' => demand.shm_mib, 'cpus' => demand.cpus },
        'requested_workers' => workers || 'auto', 'selected_items' => item_count, 'workers' => @workers,
        'disk' => { 'available_mib' => free_mib, 'per_worker_mib' => disk_mib,
                    'minimum_required_mib' => disk_mib * @workers }
      }
    end

    protected

    def positive_integer(value)
      unless value.is_a?(Integer) || value.is_a?(String)
        raise ArgumentError, 'image admission counts and caps must be positive integers'
      end

      parsed = Integer(value)
      raise ArgumentError, 'image admission counts and caps must be positive integers' if parsed < 1

      parsed
    end

    def optional_cap(value)
      value.nil? ? nil : positive_integer(value)
    end

    def disk_size_mib(size)
      match = /\A([1-9][0-9]*)([MGT])\z/.match(size.to_s)
      raise ArgumentError, 'worker disk size must use a positive M, G or T size' unless match

      match[1].to_i * { 'M' => 1, 'G' => 1024, 'T' => 1024 * 1024 }.fetch(match[2])
    end
  end
end
