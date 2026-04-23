# frozen_string_literal: true

module MetricHelpers
  def metric_values(metric)
    metric.values.each_with_object({}) do |(labels, value), ret|
      normalized = labels.transform_keys(&:to_sym)
      ret[normalized] = value
    end
  end

  def collect_with_registry_swap(registry, collector, client)
    registry.atomic_replace do
      collector.run_collect(client)
    end
  end
end

RSpec.configure do |config|
  config.include MetricHelpers
end
