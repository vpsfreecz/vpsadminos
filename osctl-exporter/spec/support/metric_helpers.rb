# frozen_string_literal: true

module MetricHelpers
  def metric_values(metric)
    metric.values.each_with_object({}) do |(labels, value), ret|
      normalized = labels.transform_keys(&:to_sym)
      ret[normalized] = value
    end
  end
end

RSpec.configure do |config|
  config.include MetricHelpers
end
