require 'prometheus/client/registry'
require 'prometheus/client/data_stores/synchronized'

class Prometheus::Client::Metric
  def initialize_copy(_other)
    @validator = @validator.clone
    @labels = @labels.clone
    @store_settings = @store_settings.clone
    @preset_labels = @preset_labels.clone
    @store = @store.clone
  end
end

Prometheus::Client::DataStores::Synchronized.send(:const_get, :MetricStore).class_eval do
  def initialize_copy(_other)
    @internal_store = @internal_store.clone
    @lock = Thread::Mutex.new
  end
end

class Prometheus::Client::Registry
  def initialize_copy(_other)
    @metrics = @metrics.transform_values(&:clone)
    @mutex = Mutex.new
  end
end
