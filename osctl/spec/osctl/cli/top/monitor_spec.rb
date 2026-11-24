# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe OsCtl::Cli::Top::Monitor do
  let(:model) { double('model') }

  before do
    allow(model).to receive(:sync).and_yield
    allow(model).to receive(:netif_enabled?).and_return(true)
    allow(model).to receive(:changed!)
    allow(model).to receive(:missing_lifecycle)
    allow(model).to receive(:monitor_ready)
    allow(model).to receive(:monitor_unavailable)
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

  it 'fences a bad subscription acknowledgement without starting a worker' do
    client = instance_double(OsCtl::Client, open: nil, close: nil)
    allow(OsCtl::Client).to receive(:new).and_return(client)
    allow(client).to receive(:cmd_data!).with(:event_subscribe).and_return(false)
    monitor = described_class.new(model)
    monitor.subscribe
    monitor.start
    monitor.stop
    expect(model).to have_received(:monitor_unavailable).with(startup: true).once
    expect(model).not_to have_received(:monitor_ready)
  end

  it 'applies buffered events before acknowledging setup and fences subscriber EOF' do
    client = instance_double(OsCtl::Client, open: nil, close: nil)
    allow(OsCtl::Client).to receive(:new).and_return(client)
    allow(client).to receive(:cmd_data!).with(:event_subscribe).and_return('subscribed')
    allow(Thread).to receive(:new).and_return(instance_double(Thread))
    monitor = described_class.new(model)
    applied = []
    allow(model).to receive(:missing_lifecycle) { |_, id| applied << id }
    allow(model).to receive(:monitor_ready) { applied << :ready }
    allow(model).to receive(:find_ct).and_return(nil)
    monitor.subscribe
    monitor.send(:save_event, type: 'ct_init_pid', opts: { pool: 'tank', id: 'before' })
    monitor.start
    allow(client).to receive(:response!).and_return(
      double(data: { type: 'ct_init_pid', opts: { pool: 'tank', id: 'after' } }), double(data: nil)
    )
    # The earlier event was already applied at startup; no new event was
    # required to flush it.
    monitor.send(:monitor_loop)
    expect(applied).to eq(['before', :ready, 'after'])
    expect(model).to have_received(:monitor_unavailable).with(startup: false).once
  end

  it 'unblocks the reader on local teardown without reporting monitor loss' do
    reader, writer = IO.pipe
    client = instance_double(OsCtl::Client, open: nil)
    allow(client).to receive(:cmd_data!).with(:event_subscribe).and_return('subscribed')
    reading = Queue.new
    allow(client).to receive(:response!) do
      reading << true
      reader.read
    end
    allow(client).to receive(:close) { reader.close }
    allow(OsCtl::Client).to receive(:new).and_return(client)
    monitor = described_class.new(model)
    monitor.subscribe
    expect(reading.pop(timeout: 2)).to be(true)

    2.times { monitor.stop }

    expect(client).to have_received(:close).once
    expect(model).not_to have_received(:monitor_unavailable)
  ensure
    writer&.close
    monitor&.stop
  end

  it 'cancels the monitor worker’s secondary lookup without reporting event loss' do
    r, w = IO.pipe
    entered = Queue.new
    subscribed = Queue.new
    subscriber = instance_double(OsCtl::Client, open: nil, close: nil)
    allow(subscriber).to receive(:cmd_data!).with(:event_subscribe).and_return('subscribed')
    allow(subscriber).to receive(:response!) do
      subscribed.pop
      double(data: { type: 'db', opts: { object: 'container', action: 'add', pool: 'tank', id: 'new' } })
    end
    primary = FakeClientHelpers::ClientDouble.new(cmd_data: { ct_list: [[]] })
    lookup = instance_double(OsCtl::Client, socket: r)
    allow(lookup).to receive(:open) do
      entered << true
      r.read
    end
    allow(lookup).to receive(:close) { r.close }
    stub_osctld_clients(subscriber, primary, lookup)
    allow(OsCtl::Lib::CGroup).to receive(:v1?).and_return(false)
    sample = OsCtl::Cli::Top::Model.new(enable_netif: false, enable_zfs: false)
    allow(sample).to receive(:monitor_unavailable)
    monitor = sample.send(:monitor)
    monitor.start
    subscribed << true
    expect(entered.pop(timeout: 2)).to be(true)
    worker = monitor.send(:thread)

    Timeout.timeout(2) { 2.times { monitor.stop } }

    expect(worker).not_to be_alive
    expect(lookup).to have_received(:close).once
    expect(sample).not_to have_received(:monitor_unavailable)
  ensure
    w&.close
    subscribed&.push(true)
    worker&.join(1)
    r&.close unless r&.closed?
  end

  it 'updates container state, scheduling, init pid, and interfaces from events' do
    ct = OsCtl::Cli::Top::Container.new(
      id: 'ct1',
      pool: 'tank',
      dataset: 'tank/ct1',
      group_path: '/grp',
      state: 'running',
      cpu_package_inuse: nil,
      init_pid: 10
    )
    ct.netifs << OsCtl::Cli::Top::Container::NetIf.new(name: 'eth0', veth: 'veth0')
    allow(model).to receive(:find_ct).and_return(ct)
    allow(model).to receive(:add_ct_netif)
    monitor = described_class.new(model)

    monitor.send(:process_event, :state, pool: 'tank', id: 'ct1', state: 'stopped', init_pid: 20)
    monitor.send(:process_event, :ct_scheduled, pool: 'tank', id: 'ct1', cpu_package_inuse: 2)
    monitor.send(:process_event, :ct_init_pid, pool: 'tank', id: 'ct1', init_pid: 30)
    monitor.send(:process_event, :ct_netif, pool: 'tank', id: 'ct1', action: 'rename', name: 'eth0', new_name: 'lan0')
    monitor.send(:process_event, :ct_netif, pool: 'tank', id: 'ct1', action: 'down', name: 'lan0')
    monitor.send(:process_event, :ct_netif, pool: 'tank', id: 'ct1', action: 'remove', name: 'lan0')

    expect(ct.state).to eq(:stopped)
    expect(ct.cpu_package_inuse).to eq(2)
    expect(ct.init_pid).to eq(30)
    expect(ct.netifs).to be_empty
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

  it 'ignores disabled network events before locking, lookup, buffering or RPC' do
    allow(model).to receive(:netif_enabled?).and_return(false)
    expect(model).not_to receive(:sync)
    expect(model).not_to receive(:find_ct)
    expect(model).not_to receive(:add_ct_netif)
    monitor = described_class.new(model)
    monitor.send(:save_event, type: 'ct_netif', opts: { action: 'add' })
    monitor.send(:process_event, :ct_netif, action: 'add')
    expect(monitor.instance_variable_get(:@buffer)).to be_empty
  end
end
