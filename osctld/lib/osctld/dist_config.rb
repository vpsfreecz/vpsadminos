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

    # @param ctrc [Container::RunConfiruration]
    # @param cmd [Symbol]
    # @param opts [Hash]
    def self.run(ctrc, cmd, opts = {})
      klass = self.for(ctrc.distribution.to_sym)

      # Make sure the container's dataset is mounted
      ctrc.mount

      d = (klass || self.for(:unsupported)).new(ctrc)

      begin
        d.method(cmd).call(opts)

      rescue Exception => e
        ctrc.log(:warn, "DistConfig.#{cmd} failed: #{e.message}")
        ctrc.log(:warn, denixstorify(e.backtrace).join("\n"))
      end
    end
  end
end
