module OsCtl::Exporter
  class Collectors::Base
    # @param registry [Prometheus::Client::Registry]
    # @param client [OsCtl::Exporter::OsCtldClient]
    def initialize(registry, client)
      @registry = registry
      @client = client
      setup
    end

    def setup
    end

    def collect
      raise NotImplementedError
    end

    protected
    attr_reader :registry, :client
  end
end
