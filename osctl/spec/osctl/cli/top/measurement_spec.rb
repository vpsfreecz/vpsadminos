# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Measurement do
  let(:stats) do
    double(
      'stats',
      write_ios: 2,
      read_ios: 1,
      write_bytes: 20,
      read_bytes: 10
    )
  end

  let(:objsets) do
    double('objsets').tap do |dbl|
      allow(dbl).to receive_messages(aggregate_stats: stats, '[]': double(aggregate_stats: stats))
    end
  end

  let(:host) do
    double(
      'host',
      netif_stats: double(
        get_stats_for_all: {
          'veth0' => { tx: { bytes: 10, packets: 1 }, rx: { bytes: 20, packets: 2 } }
        },
        get_stats_for: { tx: { bytes: 1, packets: 1 }, rx: { bytes: 2, packets: 2 } }
      ),
      objsets:
    )
  end

  before do
    allow(OsCtl::Lib::CGroup::PathReader).to receive(:new).and_return(
      instance_double(
        OsCtl::Lib::CGroup::PathReader,
        read_stats: { cpu_us: 10, cpu_hz: 20, cpu_limit: 30, memory: 40, memory_limit: 50, nproc: 2 }
      )
    )
  end

  it 'measures cgroup, zfs, and aggregated network stats' do
    measurement = described_class.new(host, {}, '/grp', nil, :all)

    measurement.measure

    expect(measurement.data).to include(
      cpu_us: 10,
      cpu_hz: 20,
      memory: 40,
      zfsio: { ios: { w: 2, r: 1 }, bytes: { w: 20, r: 10 } },
      tx: { bytes: 10, packets: 1 },
      rx: { bytes: 20, packets: 2 }
    )
  end

  it 'aggregates per-veth network stats and handles missing datasets' do
    allow(host.objsets).to receive(:[]).with('missing').and_return(nil)
    netif = double('netif', veth: 'veth0')
    measurement = described_class.new(host, {}, '/grp', 'missing', [netif])

    measurement.measure

    expect(measurement.data[:tx]).to eq(bytes: 2, packets: 2)
    expect(measurement.data[:rx]).to eq(bytes: 1, packets: 1)
    expect(measurement.data[:zfsio]).to eq(ios: { w: 0, r: 0 }, bytes: { w: 0, r: 0 })
  end

  it 'computes realtime and cumulative diffs and clamps negatives' do
    measurement = described_class.allocate

    expect(
      measurement.send(:do_diff_from, { cpu_us: 20, nested: { a: 5 } }, { cpu_us: 10, nested: { a: 1 } }, :cumulative, 2)
    ).to eq(cpu_us: 0, nested: { a: 0 })

    expect(
      measurement.send(:do_diff_from, { cpu_us: 10 }, { cpu_us: 14 }, :realtime, 2)
    ).to eq(cpu_us: 2)
  end

  it 'maps system call errors to measurement errors' do
    allow(OsCtl::Lib::CGroup::PathReader).to receive(:new).and_raise(Errno::ENOENT)

    measurement = described_class.new(host, {}, '/grp', nil, :all)

    expect { measurement.measure }.to raise_error(described_class::Error)
  end
end
