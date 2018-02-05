module OsCtld
  class PrLimit
    PARAMS = %i(name soft hard)
    attr_reader :name, :soft, :hard

    # Load from config
    def self.load(cfg)
      new(* PARAMS.map { |v| cfg[v.to_s] })
    end

    def initialize(name, soft, hard)
      @name = name
      @soft = soft
      @hard = hard
    end

    def set(soft, hard)
      @soft = soft
      @hard = hard
    end

    # Export to client
    def export
      Hash[PARAMS.map { |v| [v, instance_variable_get(:"@#{v}")] }]
    end

    # Dump to config
    def dump
      Hash[PARAMS.map { |v| [v.to_s, instance_variable_get(:"@#{v}")] }]
    end
  end
end
