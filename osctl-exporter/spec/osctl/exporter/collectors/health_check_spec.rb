# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::HealthCheck do
  it 'exports asset-count aggregation by entity' do
    registry = OsCtl::Exporter::Registry.new
    collector = described_class.new(instance_double(OsCtl::Exporter::Collector), registry)
    client = build_connected_osctld_client(
      health_check: [
        { pool: 'tank', type: 'container', id: 'ct1', assets: %w[a b] },
        { pool: 'tank', type: 'pool', id: 'tank', assets: ['a'] }
      ]
    )

    collector.run_collect(client)

    expect(metric_values(registry.get(:osctl_health_check_error_count))).to eq(
      {
        { pool: 'tank', entity_type: 'container', entity_id: 'ct1' } => 2.0,
        { pool: 'tank', entity_type: 'pool', entity_id: 'tank' } => 1.0
      }
    )
  end
end
