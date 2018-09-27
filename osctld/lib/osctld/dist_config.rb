module OsCtld
  module DistConfig
    def self.register(distribution, klass)
      @dists ||= {}
      @dists[distribution] = klass
    end

    def self.for(distribution)
      @dists[distribution]
    end

    def self.run(ct, cmd, opts = {})
      klass = self.for(ct.distribution.to_sym)

      # Make sure the container's dataset is mounted
      ct.mount

      d = (klass || self.for(:unsupported)).new(ct)
      d.method(cmd).call(opts)
    end
  end
end
