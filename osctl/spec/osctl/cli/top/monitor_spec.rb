# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Monitor do
  let(:model) { double('model') }

  before do
    allow(model).to receive(:sync).and_yield
  end

  it 'subscribes to events and starts a monitor thread' do
    client = FakeClientHelpers::ClientDouble.new(cmd_data: { event_subscribe: ['subscribed'] })
    stub_osctld_client(client)
    thread = instance_double(Thread, join: nil)
    allow(Thread).to receive(:new).and_return(thread)
    monitor = described_class.new(model)
    allow(monitor).to receive(:monitor_loop)

    monitor.subscribe

    expect(client.calls).to include([:cmd_data!, :event_subscribe, {}])
  end

  it 'updates container state, scheduling, init pid, and interfaces from events' do
    ct = OsCtl::Cli::Top::Container.new(
      id: 'ct1',
      pool: 'tank',
      dataset: 'tank/ct1',
      group_path: '/grp',
      runtime_state: 'running',
      cpu_package_inuse: nil,
      init_pid: 10
    )
    ct.netifs << OsCtl::Cli::Top::Container::NetIf.new(name: 'eth0', veth: 'veth0')
    allow(model).to receive(:find_ct).and_return(ct)
    allow(model).to receive(:add_ct_netif)
    monitor = described_class.new(model)

    monitor.send(:process_event, :runtime_state, pool: 'tank', id: 'ct1', runtime_state: 'stopped', init_pid: 20)
    monitor.send(:process_event, :ct_scheduled, pool: 'tank', id: 'ct1', cpu_package_inuse: 2)
    monitor.send(:process_event, :ct_init_pid, pool: 'tank', id: 'ct1', init_pid: 30)
    monitor.send(:process_event, :ct_netif, pool: 'tank', id: 'ct1', action: 'rename', name: 'eth0', new_name: 'lan0')
    monitor.send(:process_event, :ct_netif, pool: 'tank', id: 'ct1', action: 'down', name: 'lan0')
    monitor.send(:process_event, :ct_netif, pool: 'tank', id: 'ct1', action: 'remove', name: 'lan0')

    expect(ct.runtime_state).to eq(:stopped)
    expect(ct.cpu_package_inuse).to eq(2)
    expect(ct.init_pid).to eq(30)
    expect(ct.netifs).to be_empty
  end

  it 'accepts legacy state events during an in-place upgrade' do
    ct = OsCtl::Cli::Top::Container.new(
      id: 'ct1',
      pool: 'tank',
      dataset: 'tank/ct1',
      group_path: '/grp',
      state: 'running',
      cpu_package_inuse: nil,
      init_pid: 10
    )
    allow(model).to receive(:find_ct).and_return(ct)
    monitor = described_class.new(model)

    monitor.send(:process_event, :state, pool: 'tank', id: 'ct1', state: 'stopped')

    expect(ct.runtime_state).to eq(:stopped)
  end

  it 'adds and removes pools and containers from db events' do
    allow(model).to receive(:has_pool?).with('tank').and_return(false)
    allow(model).to receive(:add_pool)
    allow(model).to receive(:remove_pool)
    allow(model).to receive(:has_ct?).with('tank', 'ct1').and_return(false)
    allow(model).to receive(:add_ct)
    allow(model).to receive(:find_ct).with('tank', 'ct1').and_return(:ct)
    allow(model).to receive(:remove_ct)
    monitor = described_class.new(model)

    monitor.send(:process_event, :db, object: 'pool', action: 'add', pool: 'tank')
    monitor.send(:process_event, :db, object: 'pool', action: 'remove', pool: 'tank')
    monitor.send(:process_event, :db, object: 'container', action: 'add', pool: 'tank', id: 'ct1')
    monitor.send(:process_event, :db, object: 'container', action: 'remove', pool: 'tank', id: 'ct1')

    expect(model).to have_received(:add_pool).with('tank')
    expect(model).to have_received(:remove_pool).with('tank')
    expect(model).to have_received(:add_ct).with('tank', 'ct1')
    expect(model).to have_received(:remove_ct).with(:ct)
  end

  it 'buffers events until started and then processes them' do
    allow(model).to receive(:has_pool?).and_return(false)
    allow(model).to receive(:add_pool)
    monitor = described_class.new(model)

    monitor.send(:save_event, type: 'db', opts: { object: 'pool', action: 'add', pool: 'tank' })
    monitor.start
    monitor.send(:process_saved_events)

    expect(model).to have_received(:add_pool).with('tank')
  end
end
