# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles

require 'osctld/container/recovery'
require 'osctld/apparmor'
require 'osctld/hook'
require 'osctld/eventd'
require 'osctld/lockable'
require 'osctld/utils/ip'
require 'osctld/utils/switch_user'
require 'osctld/net_interface'
require 'osctld/net_interface/veth'
require 'osctld/net_interface/manager'
require 'rbconfig'

RSpec.describe OsCtld::Container::Recovery do
  let(:pool) { FakeObjects::FakePool.new(name: 'tank') }
  let(:route) { double(addr: double(to_string: '10.0.0.1/32')) }
  let(:routes) { double }
  let(:netif) { double(type: :routed, routes: routes, veth: 'veth0') }
  let(:ct) do
    double(
      pool: pool,
      id: 'ct1',
      ident: 'tank:ct1',
      netifs: [netif]
    )
  end
  let(:recovery) { described_class.new(ct) }

  before do
    stub_const(
      'OsCtld::DB::Containers',
      Class.new do
        def self.get; end
      end
    )
    allow(OsCtld::Container::Recovery::RouteList).to receive(:new).and_return(
      double(veth_of: 'veth0')
    )
    allow(recovery).to receive(:syscmd)
    allow(recovery).to receive(:log)
    allow(routes).to receive(:each_version) do |_ip_v, &block|
      block.call(route)
    end
  end

  it 'removes stale veths that only the recovered container references' do
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct])

    yielded = []
    recovery.cleanup_netifs do |veth, found_routes|
      yielded << [veth, found_routes]
    end

    expect(yielded).to eq([['veth0', [route, route]]])
    expect(recovery).to have_received(:syscmd).with('ip link delete veth0')
  end

  it 'keeps veths that another container still references' do
    other_netif = double(veth: 'veth0')
    other_ct = double(netifs: [other_netif], ident: 'tank:ct2')
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct, other_ct])

    recovery.cleanup_netifs

    expect(recovery).not_to have_received(:syscmd).with('ip link delete veth0')
  end

  context 'when recovering parent-owned runtime state' do
    let(:ct) do
      Struct.new(:pool, :id, :netifs, :state, :run_conf) do
        def stopped
          self.run_conf = nil
        end
      end.new(pool, 'ct1', nil, :running, Object.new)
    end
    let(:netif) { OsCtld::NetInterface::Veth.new(ct, 0) }
    let(:recovery) do
      described_class.new(ct, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2)
    end

    before do
      allow(OsCtld::LockRegistry).to receive(:register)
      allow(OsCtl::Lib::Logger).to receive(:log)
      allow(OsCtld::AppArmor).to receive(:enabled?).and_return(false)
      allow(OsCtld::Hook).to receive(:run)
      allow(OsCtld::Eventd).to receive(:report)
      netif.create(name: 'eth0')
      netif.up('veth-test')
      ct.netifs = OsCtld::NetInterface::Manager.new(ct, entries: [netif])
      # Exercise a real external command without changing the host's network.
      allow(netif).to receive(:syscmd) do |_cmd, opts|
        netif.syscmd_argv([RbConfig.ruby, '-e', 'print Process.pid'], opts)
      end
    end

    it 'fails before the stop deadline when a daemon thread keeps the interface lock' do
      ready = Queue.new
      release = Queue.new
      holder = Thread.new do
        netif.exclusively do
          ready << true
          release.pop
        end
      end
      pop_with_timeout(ready)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = started + 0.05
      bounded_recovery = described_class.new(ct, deadline:)
      expect do
        OsCtld::Lockable.with_deadline(deadline) do
          bounded_recovery.recover_state(state: :stopped)
        end
      end.to raise_error(OsCtld::DeadlockDetected)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.3
      expect(ct.run_conf).not_to be_nil
      expect(OsCtld::Hook).not_to have_received(:run)
    ensure
      release << true
      holder&.join
    end

    it 'executes commands separately while preserving parent netif state, hooks and events' do
      parent_pid = Process.pid
      event_pids = []
      hook_pids = []
      allow(OsCtld::Eventd).to receive(:report) { event_pids << Process.pid }
      allow(OsCtld::Hook).to receive(:run) { hook_pids << Process.pid }
      spawned = []
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args, **opts|
        original.call(*args, **opts).tap { |pid| spawned << pid }
      end
      ready = Queue.new
      holder = Thread.new do
        netif.exclusively do
          ready << true
          sleep(0.05)
        end
      end
      ready.pop
      recovery.recover_state(state: :stopped)
      holder.join

      expect(spawned.length).to eq(1)
      expect(spawned.first).not_to eq(parent_pid)
      expect(netif.veth).to be_nil
      expect(ct.state).to eq(:stopped)
      expect(ct.run_conf).to be_nil
      expect(event_pids).to all(eq(parent_pid))
      expect(hook_pids).to eq([parent_pid])
      expect(OsCtld::Eventd).to have_received(:report).with(
        :ct_netif, hash_including(action: :down, name: 'eth0')
      )
    ensure
      holder&.join
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles
