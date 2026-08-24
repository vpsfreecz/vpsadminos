# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::Pool do
  let(:registry) { OsCtl::Exporter::Registry.new }
  let(:collector) { described_class.new(instance_double(OsCtl::Exporter::Collector), registry) }

  it 'exports pool counts and container counts by state while ignoring invalid states' do
    client = build_connected_osctld_client(
      list_pools: [
        { name: 'tank', state: 'active' },
        { name: 'backup', state: 'disabled' },
        { name: 'broken', state: 'mystery' }
      ],
      list_containers: [
        { pool: 'tank', config_state: 'ready', runtime_state: 'running' },
        { pool: 'tank', config_state: 'ready', runtime_state: 'running' },
        { pool: 'tank', config_state: 'error', runtime_state: 'stopped' },
        { pool: 'backup', config_state: 'staged', runtime_state: 'unknown' },
        { pool: 'ghost', config_state: 'ready', runtime_state: 'running' }
      ]
    )
    allow(collector).to receive(:log)

    collector.run_collect(client)

    expect(metric_values(registry.get(:osctl_pool_count))).to eq(
      { { state: 'importing' } => 0.0, { state: 'active' } => 1.0, { state: 'disabled' } => 1.0 }
    )
    expect(metric_values(registry.get(:osctl_pool_containers_config_count))).to include(
      { pool: 'tank', state: 'ready' } => 2.0,
      { pool: 'tank', state: 'error' } => 1.0,
      { pool: 'backup', state: 'staged' } => 1.0
    )
    expect(metric_values(registry.get(:osctl_pool_containers_runtime_count))).to include(
      { pool: 'tank', state: 'running' } => 2.0,
      { pool: 'tank', state: 'stopped' } => 1.0,
      { pool: 'backup', state: 'unknown' } => 1.0
    )
    expect(collector).to have_received(:log).with(:warn, "Pool broken is in invalid state 'mystery'")
  end
end
