# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::ZpoolList do
  it 'exports pool metrics on success and resets both success gauges on failure' do
    registry = OsCtl::Exporter::Registry.new
    collector = described_class.new(instance_double(OsCtl::Exporter::Collector), registry)

    calls = 0
    allow(collector).to receive(:`) do |_cmd|
      calls += 1

      if calls == 1
        system('true')
        "tank\tONLINE\t12\t34\nbackup\tDEGRADED\t56\t78\n"
      else
        system('false')
        ''
      end
    end

    collect_with_registry_swap(registry, collector, build_disconnected_osctld_client)
    expect(metric_values(registry.get(:zpool_list_success))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:zpool_list_parse_success))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:zpool_list_health))).to eq(
      { { pool: 'tank' } => 1.0, { pool: 'backup' } => 0.0 }
    )

    collect_with_registry_swap(registry, collector, build_disconnected_osctld_client)
    expect(metric_values(registry.get(:zpool_list_success))).to eq({ {} => 0.0 })
    expect(metric_values(registry.get(:zpool_list_parse_success))).to eq({ {} => 0.0 })
  end
end
