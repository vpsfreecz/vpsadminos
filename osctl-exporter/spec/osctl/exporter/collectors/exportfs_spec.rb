# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::Exportfs do
  let(:registry) { OsCtl::Exporter::Registry.new }
  let(:collector) { described_class.new(instance_double(OsCtl::Exporter::Collector), registry) }

  it 'emits no metrics when osctl-exportfs is disabled' do
    allow(OsCtl::ExportFS).to receive(:enabled?).and_return(false)

    collector.run_collect(build_disconnected_osctld_client)

    expect(metric_values(registry.get(:osctl_exportfs_server_count))).to eq({})
  end

  it 'exports server counts and host-side network stats with server labels' do
    allow(OsCtl::ExportFS).to receive(:enabled?).and_return(true)
    cfg_a = instance_double(OsCtl::ExportFS::Config::TopLevel, netif: 'nfs-a', address: '192.0.2.1')
    cfg_b = instance_double(OsCtl::ExportFS::Config::TopLevel, netif: 'nfs-b', address: '192.0.2.2')
    server_a = instance_double(OsCtl::ExportFS::Server, name: 'alpha', running?: true, open_config: cfg_a)
    server_b = instance_double(OsCtl::ExportFS::Server, name: 'beta', running?: false, open_config: cfg_b)
    stats = instance_double(OsCtl::Lib::NetifStats)

    allow(OsCtl::ExportFS::Operations::Server::List).to receive(:run).and_return([server_a, server_b])
    allow(OsCtl::Lib::NetifStats).to receive(:new).and_return(stats)
    allow(stats).to receive(:get_stats_for).with('nfs-a').and_return(
      tx: { bytes: 100, packets: 10 },
      rx: { bytes: 200, packets: 20 }
    )

    collector.run_collect(build_disconnected_osctld_client)

    expect(metric_values(registry.get(:osctl_exportfs_server_count))).to eq(
      { { state: 'running' } => 1.0, { state: 'stopped' } => 1.0 }
    )
    labels = { nfs_server: 'alpha', hostdevice: 'nfs-a', ip_address: '192.0.2.1' }
    expect(metric_values(registry.get(:osctl_exportfs_server_receive_bytes_total))).to eq({ labels => 100.0 })
    expect(metric_values(registry.get(:osctl_exportfs_server_transmit_bytes_total))).to eq({ labels => 200.0 })
    expect(metric_values(registry.get(:osctl_exportfs_server_receive_packets_total))).to eq({ labels => 10.0 })
    expect(metric_values(registry.get(:osctl_exportfs_server_transmit_packets_total))).to eq({ labels => 20.0 })
  end
end
