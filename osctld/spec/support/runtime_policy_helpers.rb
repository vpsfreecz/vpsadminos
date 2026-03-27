# frozen_string_literal: true

module RuntimePolicyHelpers
  class RecordingExecutor
    attr_reader :enqueued, :removed_ids, :resized_to, :executed, :last_timeout

    def initialize
      @enqueued = []
      @removed_ids = []
      @executed = []
      @resized_to = nil
      @cleared = false
      @stopped = false
      @waited = false
    end

    def <<(cmds)
      @enqueued.concat(Array(cmds))
    end

    def execute(cmd, timeout: nil)
      @executed << cmd
      @last_timeout = timeout
      cmd.send(:exec)
    end

    def remove(id)
      @removed_ids << id
    end

    def clear
      @cleared = true
      @enqueued.clear
    end

    def resize(size)
      @resized_to = size
    end

    def stop
      @stopped = true
    end

    def wait_until_empty
      @waited = true
    end

    def queue
      enqueued.dup
    end

    def cleared?
      @cleared
    end

    def stopped?
      @stopped
    end

    def waited?
      @waited
    end
  end

  FakeCpuMask = Struct.new(:cpus) do
    def size
      cpus.size
    end

    def to_a
      cpus
    end

    def to_s
      cpus.join(',')
    end

    def &(other)
      self.class.new(cpus & other.to_a)
    end
  end

  FakeTopologyPackage = Struct.new(:id, :cpus, keyword_init: true)
  FakeTopology = Struct.new(:packages, :cpus, keyword_init: true)

  FakeAutostart = Struct.new(:priority, :delay, :ct_id, keyword_init: true) do
    def <=>(other)
      [priority, ct_id] <=> [other.priority, other.ct_id]
    end
  end
end

RSpec.configure do |config|
  config.include RuntimePolicyHelpers
end
