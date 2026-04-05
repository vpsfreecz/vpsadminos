# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::OsCtld do
  let(:registry) { OsCtl::Exporter::Registry.new }
  let(:collector) { described_class.new(instance_double(OsCtl::Exporter::Collector), registry) }

  it 'exports zeroed metrics for a disconnected client' do
    client = build_disconnected_osctld_client

    collector.run_collect(client)

    expect(metric_values(registry.get(:osctld_up))).to eq({ {} => 0.0 })
    expect(metric_values(registry.get(:osctld_responsive))).to eq({ {} => 0.0 })
    expect(metric_values(registry.get(:osctld_initialized))).to eq({ {} => 0.0 })
    expect(metric_values(registry.get(:osctld_start_time_seconds))).to eq({ {} => 0.0 })
  end

  it 'reports an unresponsive but connected daemon' do
    client = build_connected_osctld_client
    allow(client).to receive(:ping?).and_raise(RuntimeError, 'timeout')

    collector.run_collect(client)

    expect(metric_values(registry.get(:osctld_up))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:osctld_responsive))).to eq({ {} => 0.0 })
    expect(metric_values(registry.get(:osctld_initialized))).to eq({ {} => 0.0 })
    expect(metric_values(registry.get(:osctld_start_time_seconds))).to eq({ {} => 0.0 })
  end

  it 'exports the start timestamp instead of uptime for a healthy daemon' do
    client = build_connected_osctld_client(
      status: {
        initialized: true,
        started_at: Time.at(1_700_000_000)
      }
    )

    collector.run_collect(client)

    expect(metric_values(registry.get(:osctld_up))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:osctld_responsive))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:osctld_initialized))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:osctld_start_time_seconds))).to eq({ {} => 1_700_000_000.0 })
  end
end
