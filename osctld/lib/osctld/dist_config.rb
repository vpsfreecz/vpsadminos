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
    # @param opts [Hash] options
    # @option opts [IO, nil] :mount_ns_io
    # @option opts [Integer, nil] :ns_pid
    # @return [DistConfig::Base]
    def self.new(ctrc, dcopts = {})
      klass = self.for(ctrc.distribution.to_sym)
      (klass || self.for(:unsupported)).new(ctrc, dcopts)
    end

    # @param ctrc [Container::RunConfiruration]
    # @param cmd [Symbol]
    # @param opts [Hash] command options
    # @param dcopts [Hash] distconfig options
    # @option dcopts [IO, nil] :mount_ns_io
    # @option dcopts [Integer, nil] :ns_pid
    def self.run(ctrc, cmd, opts = {}, dcopts = {})
      d = new(ctrc, dcopts)

      begin
        d.method(cmd).call(opts)

      rescue Exception => e
        ctrc.log(:warn, "DistConfig.#{cmd} failed: #{e.message}")
        ctrc.log(:warn, denixstorify(e.backtrace).join("\n"))
        nil
      end
    end
  end
end
