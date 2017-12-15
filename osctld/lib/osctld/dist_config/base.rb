module OsCtld
  class DistConfig::Base
    def self.distribution(n = nil)
      if n
        DistConfig.register(n, self)

      else
        n
      end
    end

    attr_reader :ct, :distribution, :version

    def initialize(ct)
      @ct = ct
      @distribution = ct.distribution
      @version = ct.version
    end

    def network
      raise NotImplementedError
    end
  end
end
