# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::CpuScheduler do
  let(:container_collector) { instance_double(OsCtl::Exporter::Collectors::Container, get_last_container_data: container_data) }
  let(:manager) { instance_double(OsCtl::Exporter::Collector, get_collector_by_class: container_collector) }
  let(:registry) { OsCtl::Exporter::Registry.new }
  let(:collector) { described_class.new(manager, registry) }
  let(:container_data) { nil }

  it 'exports scheduler flags and returns early for a single package' do
    client = build_connected_osctld_client(
      cpu_scheduler_status: { enabled: true, needed: false, use: true },
      list_cpu_packages: [{ id: 0, enabled: true, containers: 2, usage_score: 12 }]
    )

    collector.run_collect(client)

    expect(metric_values(registry.get(:osctl_cpu_scheduler_enabled))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:osctl_cpu_scheduler_needed))).to eq({ {} => 0.0 })
    expect(metric_values(registry.get(:osctl_cpu_scheduler_use))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:osctl_cpu_package_enabled))).to eq({})
  end

  it 'aggregates per-package runtime stats from cached container data' do
    allow(container_collector).to receive(:get_last_container_data).and_return(
      [
        {
          cpu_package_inuse: 0,
          cpu_user_us: raw_value(11),
          cpu_system_us: raw_value(7),
          memory: raw_value(1024)
        },
        {
          cpu_package_inuse: 0,
          cpu_user_us: raw_value(5),
          cpu_system_us: raw_value(3),
          memory: raw_value(256)
        }
      ]
    )
    client = build_connected_osctld_client(
      cpu_scheduler_status: { enabled: true, needed: true, use: true },
      list_cpu_packages: [
        { id: 0, enabled: true, containers: 2, usage_score: 50 },
        { id: 1, enabled: false, containers: 0, usage_score: 0 }
      ]
    )

    collector.run_collect(client)

    expect(metric_values(registry.get(:osctl_cpu_package_enabled))).to eq(
      { { cpu_package: '0' } => 1.0, { cpu_package: '1' } => 0.0 }
    )
    expect(metric_values(registry.get(:osctl_cpu_package_containers))).to eq(
      { { cpu_package: '0' } => 2.0, { cpu_package: '1' } => 0.0 }
    )
    expect(metric_values(registry.get(:osctl_cpu_package_usage_score))).to eq(
      { { cpu_package: '0' } => 50.0, { cpu_package: '1' } => 0.0 }
    )
    expect(metric_values(registry.get(:osctl_cpu_package_cpu_microseconds_total))).to eq(
      {
        { cpu_package: '0', mode: 'user' } => 16.0,
        { cpu_package: '0', mode: 'system' } => 10.0
      }
    )
    expect(metric_values(registry.get(:osctl_cpu_package_memory_used_bytes))).to eq(
      { { cpu_package: '0' } => 1280.0 }
    )
  end
end
