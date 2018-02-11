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
      cmp = priority <=> other.priority
      cmp == 0 ? ct.id <=> other.ct.id : cmp
    end

    def dump
      {
        'priority' => priority,
        'delay' => delay,
      }
    end
  end
end
