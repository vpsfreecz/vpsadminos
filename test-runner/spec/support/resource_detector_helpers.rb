# frozen_string_literal: true

module ResourceDetectorHelpers
  class SequenceResourceDetector
    def initialize(memory_available_mib: nil, shm_available_mib: nil, cpus: nil)
      @memory_available_mib = sequence(memory_available_mib)
      @shm_available_mib = sequence(shm_available_mib)
      @cpus = sequence(cpus)
    end

    def memory_available_mib
      next_value(@memory_available_mib)
    end

    def shm_available_mib
      next_value(@shm_available_mib)
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

  def resource_detector(memory_available_mib: nil, shm_available_mib: nil, cpus: nil)
    SequenceResourceDetector.new(
      memory_available_mib:,
      shm_available_mib:,
      cpus:
    )
  end
end

RSpec.configure do |config|
  config.include ResourceDetectorHelpers
end
