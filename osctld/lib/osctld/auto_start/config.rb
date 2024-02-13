module OsCtld
  class AutoStart::Config
    def self.load(ct, cfg)
      new(ct, cfg['priority'], cfg['delay'])
    end

    attr_reader :ct, :priority, :delay

    def initialize(ct, priority, delay)
      @ct = ct
      @priority = priority
      @delay = delay
    end

    # Sort by priority and container id
    def <=>(other)
      [priority, ct.id] <=> [other.priority, other.ct.id]
    end

    def dump
      {
        'priority' => priority,
        'delay' => delay
      }
    end

    def dup(new_ct)
      ret = super()
      ret.instance_variable_set('@ct', new_ct)
      ret
    end
  end
end
