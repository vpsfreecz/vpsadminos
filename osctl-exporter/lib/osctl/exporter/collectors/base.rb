module OsCtl::Exporter
  class Collectors::Base
    # @param registry [Prometheus::Client::Registry]
    def initialize(registry)
      @metric_configs = {}
      @metrics = {}
      @registry = registry
      setup
    end

    # Implement to register metrics
    #
    # Metrics can be registered directly using {registry} or {#add_metric}.
    def setup ; end

    def run_collect(client)
      metric_configs.each_value do |m|
        registry.unregister(m.metric_name)

        instance = registry.send(m.metric_type, m.metric_name, **m.metric_opts)

        instance_variable_set(:"@#{m.variable_name}", instance)
        metrics[m.variable_name] = instance
      end

      collect(client)
    end

    # Implement to periodically set registered metrics
    # @param client [OsCtldClient]
    def collect(client)
      raise NotImplementedError
    end

    protected
    attr_reader :registry, :metric_configs, :metrics

    Metric = Struct.new(:variable_name, :metric_type, :metric_name, :metric_opts)

    # Add metric which is auto-registered and reset before each collection
    #
    # Registered metrics can be accessed using instance variables or via hash
    # {metrics}.
    def add_metric(variable_name, metric_type, metric_name, **metric_opts)
      metric_configs[variable_name] = Metric.new(
        variable_name,
        metric_type,
        metric_name,
        metric_opts,
      )
    end
  end
end
