require 'libosctl'

module OsCtld
  module DistConfig
    module Distributions ; end
    module Helpers ; end
    module Network ; end

    extend OsCtl::Lib::Utils::Exception

    def self.register(distribution, klass)
      @dists ||= {}
      @dists[distribution] = klass
    end

    def self.for(distribution)
      @dists[distribution]
    end

    # Call distribution config method and catch all exceptions
    # @param ctrc [Container::RunConfiruration]
    # @param cmd [Symbol]
    # @param opts [Hash]
    def self.run(ctrc, cmd, **opts)
      d = prepare(ctrc)

      begin
        d.method(cmd).call(opts)

      rescue Exception => e
        ctrc.log(:warn, "DistConfig.#{cmd} failed: #{e.message}")
        ctrc.log(:warn, denixstorify(e.backtrace).join("\n"))
      end
    end

    # Call distribution config method
    # @param ctrc [Container::RunConfiruration]
    # @param cmd [Symbol]
    # @param opts [Hash]
    def self.run!(ctrc, cmd, **opts)
      d = prepare(ctrc)
      d.method(cmd).call(opts)
    end

    def self.prepare(ctrc)
      klass = self.for(ctrc.distribution.to_sym)

      # Make sure the container's dataset is mounted
      ctrc.mount

      d = (klass || self.for(:other)).new(ctrc)
    end
  end
end
