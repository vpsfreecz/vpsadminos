# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Measurement do
  let(:clock) { -> { 100 } }
  let(:stats) { double(write_ios: 2, read_ios: 1, write_bytes: 20, read_bytes: 10) }
  let(:objsets) { double(aggregate_stats: stats) }
  let(:host) do
    netif = double(list_netifs: ['veth0'], verified_stats: [42, { tx: { bytes: 10, packets: 1 }, rx: { bytes: 20, packets: 2 } }])
    double(netif_stats: netif, objsets:)
  end

  before do
    reader = instance_double(OsCtl::Lib::CGroup::PathReader, read_stats: {
                                cpu_us: 10, cpu_hz: 20, cpu_limit: 30, memory: 40, memory_limit: 50, nproc: 2
                              })
    allow(OsCtl::Lib::CGroup::PathReader).to receive(:new).and_return(reader)
  end

  it 'measures cgroup, zfs, and verified aggregated network stats' do
    measurement = described_class.new(host, {}, '/grp', nil, :all)
    measurement.measure(clock:)
    expect(measurement.data).to include(cpu_us: 10, cpu_hz: 20, memory: 40,
                                        zfsio: { ios: { w: 2, r: 1 }, bytes: { w: 20, r: 10 } },
                                        tx: { bytes: 10, packets: 1 }, rx: { bytes: 20, packets: 2 })
  end

  it 'does not turn a missing dataset into zero IO' do
    allow(objsets).to receive(:[]).with('missing').and_return(nil)
    netif = double(veth: 'veth0')
    measurement = described_class.new(host, {}, '/grp', 'missing', [netif])
    measurement.measure(clock:)
    expect(measurement.data).to include(tx: { bytes: 20, packets: 2 }, rx: { bytes: 10, packets: 1 }, zfsio: nil)
  end

  it 'maps errors creating the cgroup reader to measurement errors' do
    allow(OsCtl::Lib::CGroup::PathReader).to receive(:new).and_raise(Errno::ENOENT)
    measurement = described_class.new(host, {}, '/grp', nil, :all)
    expect { measurement.measure(clock:) }.to raise_error(described_class::Error)
  end
end
