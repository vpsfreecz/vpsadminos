# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Container do
  let(:attrs) do
    {
      id: 'ct1',
      pool: 'tank',
      dataset: 'tank/ct1',
      group_path: '/tank/ct1',
      state: 'running',
      cpu_package_inuse: 1,
      init_pid: 123
    }
  end

  it 'initializes container fields and supports [] lookups' do
    ct = described_class.new(attrs)

    expect(ct[:id]).to eq('ct1')
    expect(ct[:pool]).to eq('tank')
    expect(ct[:init_pid]).to eq(123)
    expect(ct.running?).to be(true)
    expect(ct.container?).to be(true)
  end

  it 'leaves the old raw endpoint on a detached snapshot' do
    ct = described_class.new(attrs)
    host = double('host')
    clock = -> { 0 }
    first = instance_double(OsCtl::Cli::Top::Measurement, measure: nil)
    second = instance_double(OsCtl::Cli::Top::Measurement, measure: nil)
    allow(OsCtl::Cli::Top::Measurement).to receive(:new).and_return(first, second)

    ct.measure(host, {}, clock:)
    snapshot = ct.snapshot
    ct.measure(host, {}, clock:)
    expect(snapshot.current_measurement).to equal(first)
    expect(ct.current_measurement).to equal(second)
  end

  it 'updates network interfaces' do
    ct = described_class.new(attrs)
    ct.netifs << described_class::NetIf.new(name: 'eth0', veth: 'veth0')

    ct.netif_up('eth0', 'veth1')
    ct.netif_rename('eth0', 'lan0')
    ct.netif_down('lan0')
    ct.netif_rm('lan0')

    expect(ct.netifs).to be_empty
  end
end
