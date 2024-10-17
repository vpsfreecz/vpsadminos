module OsCtld
  # Identifies individual container runs
  class Container::RunId
    # @return [String]
    attr_reader :pool_name

    # @return [String]
    attr_reader :container_id

    # @return [Float]
    attr_reader :timestamp

    # @return [String]
    attr_reader :to_s

    # @param cfg [String]
    def self.load(cfg)
      new(
        pool_name: cfg.fetch('pool_name'),
        container_id: cfg.fetch('container_id'),
        timestamp: cfg.fetch('timestamp')
      )
    end

    # @param pool_name [String]
    # @param container_id [String]
    # @param timestamp [Float, nil]
    def initialize(pool_name:, container_id:, timestamp: nil)
      @pool_name = pool_name
      @container_id = container_id
      @timestamp = timestamp || Time.now.to_f
      @to_s = [@pool_name, @container_id, @timestamp].join(':')
    end

    def inspect
      "#<#{self.class.name}:#{object_id} run=#{self}>"
    end

    def ==(other)
      to_s == other.to_s
    end

    def dump
      {
        'pool_name' => pool_name,
        'container_id' => container_id,
        'timestamp' => timestamp
      }
    end
  end
end
