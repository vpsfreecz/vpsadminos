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

  it 'keeps a rolling measurement window and computes results' do
    ct = described_class.new(attrs)
    host = double('host')
    subsystems = {}
    m1 = instance_double(OsCtl::Cli::Top::Measurement, measure: nil)
    m2 = instance_double(OsCtl::Cli::Top::Measurement, measure: nil)
    m3 = instance_double(OsCtl::Cli::Top::Measurement, measure: nil)
    allow(m3).to receive(:diff_from).with(m2, :realtime).and_return(cpu: 1)
    allow(m3).to receive(:diff_from).with(m1, :cumulative).and_return(cpu: 2)
    allow(OsCtl::Cli::Top::Measurement).to receive(:new).and_return(m1, m2, m3)

    ct.measure(host, subsystems)
    ct.measure(host, subsystems)
    ct.measure(host, subsystems)

    expect(ct.setup?).to be(true)
    expect(ct.result(:realtime)).to eq(cpu: 1)
    expect(ct.result(:cumulative)).to eq(cpu: 2)
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
