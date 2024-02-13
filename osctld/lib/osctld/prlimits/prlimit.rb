module OsCtld
  class PrLimits::PrLimit
    attr_reader :name, :soft, :hard

    # Load from config
    def self.load(name, cfg)
      new(name, cfg['soft'], cfg['hard'])
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
      { soft:, hard: }
    end

    # Dump to config
    def dump
      { 'soft' => soft, 'hard' => hard }
    end
  end
end
