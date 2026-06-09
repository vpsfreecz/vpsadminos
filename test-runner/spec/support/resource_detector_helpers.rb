# frozen_string_literal: true

module ResourceDetectorHelpers
  class SequenceResourceDetector
    def initialize(memory_mib: nil, shm_mib: nil, cpus: nil)
      @memory_mib = sequence(memory_mib)
      @shm_mib = sequence(shm_mib)
      @cpus = sequence(cpus)
    end

    def memory_mib
      next_value(@memory_mib)
    end

    def shm_mib
      next_value(@shm_mib)
    end

    def cpus
      next_value(@cpus)
    end

    protected

    def sequence(value)
      Array(value)
    end

    def next_value(values)
      return nil if values.empty?
      return values.first if values.length == 1

      values.shift
    end
  end

  def resource_detector(memory_mib: nil, shm_mib: nil, cpus: nil)
    SequenceResourceDetector.new(
      memory_mib:,
      shm_mib:,
      cpus:
    )
  end
end

RSpec.configure do |config|
  config.include ResourceDetectorHelpers
end
