module TestRunner
  class TestResources
    # @return [Integer]
    attr_reader :machines

    # @return [Integer]
    attr_reader :memory_mib

    # @return [Integer]
    attr_reader :shm_mib

    # @return [Integer]
    attr_reader :max_machine_memory_mib

    # @return [Integer]
    attr_reader :cpus

    def self.from_h(data)
      data ||= {}

      memory_mib = data.fetch('memoryMiB', data.fetch(:memory_mib, 0)).to_i

      new(
        machines: data.fetch('machines', 0).to_i,
        memory_mib:,
        shm_mib: data.fetch('shmMiB', data.fetch(:shm_mib, memory_mib)).to_i,
        max_machine_memory_mib: data.fetch(
          'maxMachineMemoryMiB',
          data.fetch(:max_machine_memory_mib, 0)
        ).to_i,
        cpus: data.fetch('cpus', 0).to_i
      )
    end

    def initialize(
      machines: 0,
      memory_mib: 0,
      shm_mib: memory_mib,
      max_machine_memory_mib: 0,
      cpus: 0
    )
      @machines = machines
      @memory_mib = memory_mib
      @shm_mib = shm_mib
      @max_machine_memory_mib = max_machine_memory_mib
      @cpus = cpus
    end

    def +(other)
      self.class.new(
        machines: machines + other.machines,
        memory_mib: memory_mib + other.memory_mib,
        shm_mib: shm_mib + other.shm_mib,
        max_machine_memory_mib: [max_machine_memory_mib, other.max_machine_memory_mib].max,
        cpus: cpus + other.cpus
      )
    end

    def -(other)
      self.class.new(
        machines: machines - other.machines,
        memory_mib: memory_mib - other.memory_mib,
        shm_mib: shm_mib - other.shm_mib,
        max_machine_memory_mib: max_machine_memory_mib,
        cpus: cpus - other.cpus
      )
    end

    def zero?
      machines <= 0 && memory_mib <= 0 && shm_mib <= 0 && cpus <= 0
    end

    def summary
      "machines=#{machines}, memory=#{format_mib(memory_mib)}, " \
        "shm=#{format_mib(shm_mib)}, cpus=#{cpus}"
    end

    protected

    def format_mib(value)
      return "#{value} MiB" if value < 1024

      format('%.1f GiB', value / 1024.0)
    end
  end
end
