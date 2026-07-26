require 'digest'
require 'securerandom'

module OsCtld
  # Identifies individual container runs
  class Container::RunId
    # @return [String]
    attr_reader :pool_name

    # @return [String]
    attr_reader :container_id

    # @return [Float]
    attr_reader :timestamp

    # Filesystem/cgroup-safe random identifier
    # @return [String]
    attr_reader :key

    # @return [String]
    attr_reader :to_s

    # @param cfg [String]
    def self.load(cfg)
      key =
        cfg['key'] || Digest::SHA256.hexdigest(
          [
            cfg.fetch('pool_name'),
            cfg.fetch('container_id'),
            cfg.fetch('timestamp')
          ].join(':')
        )[0, 32]

      new(
        pool_name: cfg.fetch('pool_name'),
        container_id: cfg.fetch('container_id'),
        timestamp: cfg.fetch('timestamp'),
        key:
      )
    end

    # @param pool_name [String]
    # @param container_id [String]
    # @param timestamp [Float, nil]
    # @param key [String, nil]
    def initialize(pool_name:, container_id:, timestamp: nil, key: nil)
      @pool_name = pool_name
      @container_id = container_id
      @timestamp = timestamp || Time.now.to_f
      @key = key || SecureRandom.hex(16)
      @to_s = [@pool_name, @container_id, @key].join(':')
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
        'timestamp' => timestamp,
        'key' => key
      }
    end
  end
end
