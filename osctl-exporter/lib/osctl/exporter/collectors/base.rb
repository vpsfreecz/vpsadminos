module OsCtl::Exporter
  class Collectors::Base
    # @param registry [Prometheus::Client::Registry]
    def initialize(registry)
      @registry = registry
      setup
    end

    def setup
    end

    # @param client [OsCtldClient]
    def collect(client)
      raise NotImplementedError
    end

    protected
    attr_reader :registry
  end
end
