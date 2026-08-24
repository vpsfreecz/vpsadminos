# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Model do
  def build_model
    model = described_class.allocate
    model.instance_variable_set(:@mutex, Mutex.new)
    model.instance_variable_set(:@mode, :realtime)
    model.instance_variable_set(:@nproc, 2)
    model.instance_variable_set(:@subsystems, {})
    model.instance_variable_set(:@containers, [])
    model.instance_variable_set(:@index, OsCtl::Lib::Index.new { |ct| "#{ct.pool}:#{ct.id}" })
    model
  end

  it 'subscribes the monitor during initialization' do
    monitor = instance_double(OsCtl::Cli::Top::Monitor, subscribe: nil)
    allow(OsCtl::Cli::Top::Monitor).to receive(:new).and_return(monitor)
    allow_any_instance_of(described_class).to receive(:open)

    described_class.new(enable_iostat: false)

    expect(monitor).to have_received(:subscribe)
  end

  it 'sets up pools, iostat, and the initial measurement' do
    model = build_model
    host = instance_double(OsCtl::Cli::Top::Host, pools: [], measure: nil)
    monitor = instance_double(OsCtl::Cli::Top::Monitor, start: nil)
    iostat = instance_double(OsCtl::Lib::Zfs::IOStat, 'pools=': nil, start: nil)
    client = instance_double(FakeClientHelpers::ClientDouble)
    allow(client).to receive(:cmd_data!).with(:pool_list).and_return([{ name: 'tank' }])
    model.instance_variable_set(:@host, host)
    model.instance_variable_set(:@monitor, monitor)
    model.instance_variable_set(:@iostat, iostat)
    model.instance_variable_set(:@client, client)
    allow(model).to receive(:measure)
    stub_backticks(model, 'nproc' => "8\n")

    model.setup

    expect(host.pools).to eq(['tank'])
    expect(monitor).to have_received(:start)
    expect(iostat).to have_received(:pools=).with(['tank'])
    expect(iostat).to have_received(:start)
    expect(model).to have_received(:measure)
  end

  it 'measures the host, running containers, and marks measurement failures' do
    model = build_model
    host = instance_double(OsCtl::Cli::Top::Host, measure: nil)
    ok_ct = instance_double(OsCtl::Cli::Top::Container, running?: true, measure: nil)
    bad_ct = instance_double(OsCtl::Cli::Top::Container, running?: true)
    stopped_ct = instance_double(OsCtl::Cli::Top::Container, running?: false)
    allow(bad_ct).to receive(:measure).and_raise(OsCtl::Cli::Top::Measurement::Error, 'boom')
    allow(OsCtl::Lib::LoadAvgReader).to receive(:read_for).and_return({})
    model.instance_variable_set(:@host, host)
    model.instance_variable_set(:@containers, [ok_ct, bad_ct, stopped_ct])

    expect { model.measure }.not_to raise_error

    expect(host).to have_received(:measure).with({})
    expect(ok_ct).to have_received(:measure).with(host, {})
  end

  it 'shapes realtime data for containers and the host' do
    model = build_model
    cpu = OsCtl::Cli::Top::Host::Cpu.new(1, 0, 1, 2, 0, 0, 0, 0, 0, 0)
    host = instance_double(
      OsCtl::Cli::Top::Host,
      setup?: true,
      result: {
        cpu_user_hz: 10,
        cpu_system_hz: 10,
        memory: 100,
        zfsio: { ios: { w: 5, r: 5 }, bytes: { w: 10, r: 10 } }
      },
      cpu_result: cpu,
      zfs_result: { arcstats: {} },
      id: '[host]'
    )
    ct = instance_double(
      OsCtl::Cli::Top::Container,
      running?: true,
      setup?: true,
      result: {
        cpu_user_hz: 1,
        cpu_system_hz: 1,
        memory: 10,
        zfsio: { ios: { w: 1, r: 1 }, bytes: { w: 2, r: 2 } }
      },
      pool: 'tank',
      id: 'ct1',
      cpu_package_inuse: 1,
      init_pid: 100,
      ident: 'tank:ct1'
    )
    model.instance_variable_set(:@host, host)
    model.instance_variable_set(:@containers, [ct])
    model.instance_variable_set(:@ct_lavgs, 'tank:ct1' => double(averages: [0.1, 0.2, 0.3]))
    allow(OsCtl::Lib::MemInfo).to receive(:new).and_return(double(total: 10, used: 4, free: 6, buffers: 1, cached: 2, swap_total: 3, swap_used: 1, swap_free: 2))
    allow(OsCtl::Lib::LoadAvg).to receive(:new).and_return(double(to_a: [1.0, 2.0, 3.0]))

    data = model.data

    expect(data[:containers].map { |v| v[:id] }).to include('ct1', '[host]')
    expect(data[:memory][:used]).to eq(4096)
    expect(data[:containers].detect { |v| v[:id] == 'ct1' }[:loadavg]).to eq([0.1, 0.2, 0.3])
  end

  it 'adds and removes pools, containers, and network interfaces' do
    model = build_model
    host = instance_double(OsCtl::Cli::Top::Host, pools: [])
    iostat = instance_double(OsCtl::Lib::Zfs::IOStat, add_pool: nil, remove_pool: nil)
    client = instance_double(FakeClientHelpers::ClientDouble)
    allow(client).to receive(:cmd_data!).with(:ct_show, pool: 'tank', id: 'ct1').and_return(
      id: 'ct1', pool: 'tank', dataset: 'tank/ct1', group_path: '/grp', runtime_state: 'running', cpu_package_inuse: nil, init_pid: 10
    )
    allow(client).to receive(:cmd_data!).with(:netif_list, id: 'ct1', pool: 'tank').and_return([{ name: 'eth0', veth: 'veth0' }])
    allow(client).to receive(:cmd_data!).with(:netif_show, pool: 'tank', id: 'ct1', name: 'eth1').and_return(name: 'eth1', veth: 'veth1')
    model.instance_variable_set(:@host, host)
    model.instance_variable_set(:@iostat, iostat)
    model.instance_variable_set(:@client, client)

    model.add_pool('tank')
    model.add_ct('tank', 'ct1')
    ct = model.find_ct('tank', 'ct1')
    model.add_ct_netif(ct, 'eth1')

    expect(model.find_ct('tank', 'ct1')).to eq(ct)
    expect(ct.netifs.map(&:name)).to include('eth0', 'eth1')

    model.remove_ct(ct)
    model.remove_pool('tank')

    expect(model.find_ct('tank', 'ct1')).to be_nil
    expect(host.pools).to be_empty
  end

  it 'allows nested sync calls and computes cpu helpers' do
    model = build_model

    model.instance_variable_get(:@mutex).synchronize do
      expect { model.sync { :ok } }.not_to raise_error
    end

    expect(model.send(:calc_cpu_usage, -1, 10)).to eq(0.0)
    expect(model.send(:calc_cpu_usage, 5, 10)).to eq(100.0)
    cpu = OsCtl::Cli::Top::Host::Cpu.new(1, 0, 1, 2, 0, 0, 0, 0, 0, 0)
    expect(model.send(:calc_host_cpu_usage, cpu)[:idle]).to be > 0
  end
end
