# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::ZpoolStatus do
  it 'exports pool and vdev metrics and resets parse success on failure' do
    registry = OsCtl::Exporter::Registry.new
    collector = described_class.new(instance_double(OsCtl::Exporter::Collector), registry)
    leaf = zpool_vdev_info(
      name: '/dev/disk1',
      role: :storage,
      type: 'disk',
      state: :online,
      read: 1,
      write: 2,
      checksum: 3,
      virtual_devices: []
    )
    root_vdev = zpool_vdev_info(
      name: 'mirror-0',
      role: :storage,
      type: 'mirror',
      state: :online,
      read: 0,
      write: 0,
      checksum: 0,
      virtual_devices: [leaf]
    )
    pool = zpool_pool_info(
      name: 'tank',
      state: :online,
      scan: :scrub,
      scan_percent: 25.5,
      virtual_devices: [root_vdev]
    )
    status = zpool_status_info([pool])

    allow(OsCtl::Lib::Zfs::ZpoolStatus).to receive(:new).and_return(status)
    allow(collector).to receive(:log)

    collector.run_collect(build_disconnected_osctld_client)

    expect(metric_values(registry.get(:zpool_status_success))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:zpool_status_parse_success))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:zpool_status_state_online))).to eq({ { pool: 'tank' } => 1.0 })
    expect(metric_values(registry.get(:zpool_status_scan_scrub))).to eq({ { pool: 'tank' } => 1.0 })
    expect(metric_values(registry.get(:zpool_status_scan_percent))).to eq(
      { { pool: 'tank', scan: 'scrub' } => 25.5, { pool: 'tank', scan: 'none' } => 0.0, { pool: 'tank', scan: 'resilver' } => 0.0 }
    )
    expect(metric_values(registry.get(:zpool_status_vdev_read_errors))).to include(
      { pool: 'tank', vdev_name: '/dev/disk1', vdev_role: 'storage', vdev_type: 'disk', vdev_state: 'online' } => 1.0
    )

    allow(OsCtl::Lib::Zfs::ZpoolStatus).to receive(:new).and_raise(RuntimeError, 'parse failed')
    collector.run_collect(build_disconnected_osctld_client)

    expect(metric_values(registry.get(:zpool_status_success))).to eq({ {} => 0.0 })
    expect(metric_values(registry.get(:zpool_status_parse_success))).to eq({ {} => 0.0 })
    expect(collector).to have_received(:log).with(
      :warn,
      'Failed to parse zpool status: parse failed (RuntimeError)'
    )
  end
end
