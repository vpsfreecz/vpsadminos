require 'json'

module OsCtl::Exporter
  class Formats::Json
    MEDIA_TYPE   = 'application/json'.freeze
    VERSION      = '0.0.1'.freeze
    CONTENT_TYPE = "#{MEDIA_TYPE}; version=#{VERSION}".freeze

    def self.marshal(registry)
      registry.metrics.each_with_object({}) do |metric, ret|
        ret[metric.name] = metric.values.map do |label_set, value|
          {
            labels: label_set,
            value:
          }
        end
      end.to_json
    end
  end
end
