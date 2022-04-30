require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::HealthCheck < Collectors::Base
    def setup
      add_metric(
        :error_count,
        :gauge,
        :osctl_health_check_error_count,
        docstring: 'Number of health check errors detected by osctld',
        labels: [:pool, :entity_type, :entity_id],
      )
    end

    def collect(client)
      client.health_check.each do |entity|
        @error_count.set(entity[:assets].length, labels: {
          pool: entity[:pool],
          entity_type: entity[:type],
          entity_id: entity[:id],
        })
      end
    end
  end
end
