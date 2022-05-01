require 'thread'
require 'prometheus/client/registry'

module OsCtl::Exporter
  # Encapsulate Prometheus registry to allow atomic update of resetable metrics
  #
  # Metrics are exported from one registry, while new metrics are saved to a new
  # registry. When the new metrics have been collected, the new registry
  # atomically replaces the old one.
  #
  # This process is needed, since osctl-exporter re-register metrics to get rid
  # of old values, e.g. so that we do not export metrics for containers that
  # no longer exist. This is done by unregistering the metric and then
  # registering it again, which can lead to incomplete data being exported if
  # the client connects during this process.
  class Registry
    def initialize
      @mutex = Mutex.new
      @exported_registry = @new_registry = Prometheus::Client::Registry.new
    end

    # Replace the exported registry with a modified clone
    #
    # Metric registration is redirected to a new registry while metrics are read
    # from the original registry. After the block completes, the original
    # registry is replaced with the new one.
    #
    # @yieldparam [Prometheus::Client::Registry] the new registry
    def atomic_replace
      @mutex.synchronize do
        @new_registry = @exported_registry.clone

        begin
          yield(@new_registry)
        ensure
          @exported_registry = @new_registry
          @new_registry = @exported_registry
        end
      end

      nil
    end

    # Forward write methods to the new registry
    %i(register unregister counter summary gauge histogram).each do |m|
      define_method(m) do |*args, **kwargs|
        @new_registry.send(m, *args, **kwargs)
      end
    end

    # Forward read methods to the exported registry
    %i(exist? get metrics).each do |m|
      define_method(m) do |*args, **kwargs|
        @exported_registry.send(m, *args, **kwargs)
      end
    end
  end
end
