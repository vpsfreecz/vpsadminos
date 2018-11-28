require 'libosctl'

module OsCtld
  module DistConfig
    extend OsCtl::Lib::Utils::Exception

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

      begin
        d.method(cmd).call(opts)

      rescue Exception => e
        ct.log(:warn, "DistConfig.#{cmd} failed: #{e.message}")
        ct.log(:warn, denixstorify(e.backtrace).join("\n"))
      end
    end
  end
end
