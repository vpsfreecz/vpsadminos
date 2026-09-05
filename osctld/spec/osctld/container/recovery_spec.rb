# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles

require 'osctld/container/recovery'
require 'osctld/exceptions'

RSpec.describe OsCtld::Container::Recovery do
  let(:invalid_host_link) { Class.new(StandardError) }
  let(:pool) { FakeObjects::FakePool.new(name: 'tank') }
  let(:route) { double(addr: double(to_string: '10.0.0.1/32')) }
  let(:routes) { double }
  let(:netif) do
    double(
      name: 'eth0',
      type: :routed,
      routes:,
      host_link_identity: ['veth0', 10, 20]
    )
  end
  let(:netifs) do
    [netif].tap do |entries|
      entries.define_singleton_method(:take_down) do
        each(&:down)
      end
    end
  end
  let(:ct) do
    double(
      pool: pool,
      id: 'ct1',
      ident: 'tank:ct1',
      netifs:,
      state: :stopped,
      save_config: nil
    )
  end
  let(:recovery) { described_class.new(ct) }

  before do
    stub_const('OsCtld::AppArmor', Class.new do
      def self.enabled? = false
    end)
    stub_const('OsCtld::Hook', Class.new do
      def self.run(*); end
    end)
    stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    stub_const(
      'OsCtld::DB::Containers',
      Class.new do
        def self.get; end
      end
    )
    allow(OsCtld::Container::Recovery::RouteList).to receive(:new).and_return(
      double(veth_of: 'veth0')
    )
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct])
    allow(netif).to receive(:down)
    allow(recovery).to receive(:log)
    allow(ct).to receive(:state=)
    allow(routes).to receive(:each_version) do |_ip_v, &block|
      block.call(route)
    end
  end

  it 'delegates stale recorded-link cleanup to the owning netif' do
    yielded = []
    recovery.cleanup_netifs do |veth, found_routes|
      yielded << [veth, found_routes]
    end

    expect(yielded).to eq([['veth0', [route, route]]])
    expect(netif).to have_received(:down).with('veth0').once
  end

  it 'taints recovery when a proved recorded index disappears before deletion' do
    allow(netif).to receive(:down).and_raise(
      invalid_host_link,
      'recorded veth disappeared before deletion'
    )

    expect { recovery.cleanup_netifs }.to raise_error(
      invalid_host_link,
      /disappeared before deletion/
    )
    expect(netif).to have_received(:down).with('veth0').once
  end

  it 'propagates non-ENODEV deletion failures without touching the veth' do
    allow(netif).to receive(:down).and_raise(Errno::EPERM)

    expect { recovery.cleanup_netifs }.to raise_error(Errno::EPERM)
    expect(netif).to have_received(:down).with('veth0').once
  end

  it 'does not delete a recovery veth index reassigned to another live link' do
    allow(netif).to receive(:down).and_raise(
      invalid_host_link,
      'recorded veth index now belongs to foreign0'
    )

    expect { recovery.cleanup_netifs }.to raise_error(
      invalid_host_link,
      /belongs to foreign0/
    )
    expect(netif).to have_received(:down).with('veth0').once
  end

  it 'does not delete a recovery IFB index reassigned to another live link' do
    allow(netif).to receive(:down).and_raise(
      invalid_host_link,
      'recorded IFB index now belongs to foreign0'
    )

    expect { recovery.cleanup_netifs }.to raise_error(
      invalid_host_link,
      /belongs to foreign0/
    )
    expect(netif).to have_received(:down).with('veth0').once
  end

  it 'rejects a missing recorded veth name without deleting by a discovered name' do
    allow(netif).to receive(:host_link_identity).and_return([nil, 10, 20])

    expect { recovery.cleanup_netifs }.to raise_error(
      described_class::InvalidNetifIdentity,
      /no recorded host-veth name/
    )
    expect(netif).not_to have_received(:down)
  end

  it 'rejects a missing recorded veth ifindex' do
    allow(netif).to receive(:host_link_identity).and_return(['veth0', nil, 20])

    expect { recovery.cleanup_netifs }.to raise_error(
      described_class::InvalidNetifIdentity,
      /no valid recorded ifindex/
    )
    expect(netif).not_to have_received(:down)
  end

  it 'rejects a discovered name that differs from the recorded veth name' do
    allow(netif).to receive(:host_link_identity).and_return(['veth1', 10, 20])

    expect { recovery.cleanup_netifs }.to raise_error(
      described_class::InvalidNetifIdentity,
      /does not match recorded "veth1"/
    )
    expect(netif).not_to have_received(:down)
  end

  it 'rejects an invalid recorded IFB index' do
    allow(netif).to receive(:host_link_identity).and_return(['veth0', 10, 0])

    expect { recovery.cleanup_netifs }.to raise_error(
      described_class::InvalidNetifIdentity,
      /invalid recorded IFB ifindex 0/
    )
    expect(netif).not_to have_received(:down)
  end

  it 'rejects two routed netifs associated with one discovered name' do
    other_routes = double
    other_netif = double(
      type: :routed,
      routes: other_routes,
      host_link_identity: ['veth0', 30, nil]
    )
    allow(other_routes).to receive(:each_version) do |_ip_v, &block|
      block.call(route)
    end
    allow(ct).to receive(:netifs).and_return([netif, other_netif])

    expect { recovery.cleanup_netifs }.to raise_error(
      described_class::InvalidNetifIdentity,
      /associated with multiple routed netifs/
    )
    expect(netif).not_to have_received(:down)
  end

  it 'rejects a recorded veth name claimed by another container' do
    other_netif = double(host_link_identity: ['veth0', 30, nil])
    other_ct = double(netifs: [other_netif], ident: 'tank:ct2')
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct, other_ct])

    expect { recovery.cleanup_netifs }.to raise_error(
      described_class::InvalidNetifIdentity,
      /also claimed by container tank:ct2/
    )
    expect(netif).not_to have_received(:down)
  end

  it 'rejects a recorded veth index claimed by another container' do
    other_netif = double(host_link_identity: ['veth2', 10, nil])
    other_ct = double(netifs: [other_netif], ident: 'tank:ct2')
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct, other_ct])

    expect { recovery.cleanup_netifs }.to raise_error(
      described_class::InvalidNetifIdentity,
      /also claimed by container tank:ct2/
    )
    expect(netif).not_to have_received(:down)
  end

  it 'rejects a recorded IFB index claimed by another container' do
    other_netif = double(host_link_identity: ['veth2', 30, 20])
    other_ct = double(netifs: [other_netif], ident: 'tank:ct2')
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct, other_ct])

    expect { recovery.cleanup_netifs }.to raise_error(
      described_class::InvalidNetifIdentity,
      /also claimed by container tank:ct2/
    )
    expect(netif).not_to have_received(:down)
  end

  it 'taints the container when direct and route-based identity cleanup fail' do
    allow(recovery).to receive(:cleanup_cgroups)
    allow(netifs).to receive(:take_down).and_raise('missing recorded identity')
    allow(netif).to receive(:host_link_identity).and_return(['veth0', nil, nil])

    expect(recovery.cleanup_or_taint).to be(false)

    expect(ct).to have_received(:state=).with(:error)
    expect(netif).not_to have_received(:down)
  end

  it 'taints the container when another container claims a recorded link index' do
    other_netif = double(host_link_identity: ['veth2', 10, nil])
    other_ct = double(netifs: [other_netif], ident: 'tank:ct2')
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct, other_ct])
    allow(recovery).to receive(:cleanup_cgroups)

    expect(recovery.cleanup_or_taint).to be(false)

    expect(ct).to have_received(:state=).with(:error)
    expect(netif).not_to have_received(:down)
  end

  it 'holds the host-link registry from preflight through direct mutation' do
    events = []
    allow(recovery).to receive(:preflight_netif_cleanup) { events << :preflight }
    allow(netifs).to receive(:take_down) { events << :mutation }
    allow(OsCtld::NetInterface).to receive(:sync_host_link_registry)
      .and_wrap_original do |original, &block|
        events << :lock
        original.call do
          ret = block.call
          events << :unlock
          ret
        end
      end

    recovery.send(:take_down_netifs)

    expect(events).to eq(%i[lock preflight mutation unlock])
  end

  it 'taints the container when another container claims a recorded link name' do
    other_netif = double(host_link_identity: ['veth0', 30, nil])
    other_ct = double(netifs: [other_netif], ident: 'tank:ct2')
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct, other_ct])
    allow(recovery).to receive(:cleanup_cgroups)

    expect(recovery.cleanup_or_taint).to be(false)

    expect(ct).to have_received(:state=).with(:error)
    expect(netif).not_to have_received(:down)
  end

  it 'taints the container when another container claims a recorded IFB index' do
    other_netif = double(host_link_identity: ['veth2', 30, 20])
    other_ct = double(netifs: [other_netif], ident: 'tank:ct2')
    allow(OsCtld::DB::Containers).to receive(:get).and_return([ct, other_ct])
    allow(recovery).to receive(:cleanup_cgroups)

    expect(recovery.cleanup_or_taint).to be(false)

    expect(ct).to have_received(:state=).with(:error)
    expect(netif).not_to have_received(:down)
  end

  it 'taints the container when two of its netifs claim one recorded identity' do
    other_netif = double(
      type: :bridge,
      host_link_identity: ['veth2', 10, nil]
    )
    allow(other_netif).to receive(:down)
    conflicting_netifs = [netif, other_netif].tap do |entries|
      entries.define_singleton_method(:take_down) do
        each(&:down)
      end
    end
    allow(ct).to receive(:netifs).and_return(conflicting_netifs)
    allow(recovery).to receive(:cleanup_cgroups)

    expect(recovery.cleanup_or_taint).to be(false)

    expect(ct).to have_received(:state=).with(:error)
    expect(netif).not_to have_received(:down)
    expect(other_netif).not_to have_received(:down)
  end

  it 'taints when cleanup returns with retained host-link authority' do
    allow(recovery).to receive(:cleanup_cgroups)
    allow(recovery).to receive(:take_down_netifs)
    allow(recovery).to receive(:cleanup_netifs)

    expect(recovery.cleanup_or_taint).to be(false)

    expect(ct).to have_received(:state=).with(:error)
    expect(ct).to have_received(:save_config)
  end

  it 'persists fallback owner cleanup and clears error only on a complete retry' do
    current_identity = ['veth0', 10, 20]
    current_state = :stopped
    snapshots = []
    route_list = double
    allow(route_list).to receive(:veth_of).and_return('veth0', 'veth0', nil, nil)
    allow(OsCtld::Container::Recovery::RouteList).to receive(:new).and_return(route_list)
    allow(netif).to receive(:host_link_identity) { current_identity }
    allow(netif).to receive(:down) do |name|
      expect(name).to eq('veth0')
      current_identity = [nil, nil, nil]
      snapshots << [current_state, current_identity.dup]
    end
    take_down_calls = 0
    allow(netifs).to receive(:take_down) do
      take_down_calls += 1
      raise 'direct cleanup failed' if take_down_calls == 1
    end
    allow(recovery).to receive(:cleanup_cgroups)
    allow(ct).to receive(:state) { current_state }
    allow(ct).to receive(:state=) { |state| current_state = state }
    allow(ct).to receive(:save_config) do
      snapshots << [current_state, current_identity.dup]
    end

    expect(recovery.cleanup_or_taint).to be(false)
    expect(snapshots).to eq(
      [
        [:stopped, [nil, nil, nil]],
        [:error, [nil, nil, nil]]
      ]
    )

    # A daemon reload now sees no stale host-link identity but retains :error.
    # Only a later complete recovery pass deliberately makes it startable.
    expect(recovery.cleanup_or_taint).to be(true)
    expect(current_state).to eq(:stopped)
    expect(snapshots.last).to eq([:stopped, [nil, nil, nil]])
  end

  it 'holds the exact old run through container-global stop recovery effects' do
    events = []
    lease = instance_double(
      OsCtld::Container::RunConfiguration::LifecycleLease
    )
    run_conf = instance_double(OsCtld::Container::RunConfiguration)
    netifs = double
    apparmor = double
    recovered_ct = double(
      state: :running,
      current_state: :stopped,
      run_conf:,
      netifs:,
      apparmor:,
      pool:,
      id: 'ct1'
    )
    allow(recovered_ct).to receive(:inclusively).and_yield
    allow(run_conf).to receive(:acquire_lifecycle_lease) do
      events << :lease
      lease
    end
    allow(run_conf).to receive(:wait_for_lifecycle_leases) { events << :wait }
    allow(netifs).to receive(:each)
    allow(netifs).to receive(:take_down) { events << :netifs }
    allow(lease).to receive(:close) { events << :release }
    allow(recovered_ct).to receive(:stopped) do |expected_run, &block|
      expect(expected_run).to be(run_conf)
      block.call(true)
      events << :stopped
      true
    end
    allow(OsCtld::AppArmor).to receive(:enabled?).and_return(false)
    allow(OsCtld::Hook).to receive(:run) { events << :hook }
    allow(OsCtld::Eventd).to receive(:report)

    described_class.new(recovered_ct).recover_state

    expect(events).to eq(%i[lease netifs release wait hook stopped])
  end

  it 'runs recovery cleanup after netif teardown fails even when a hook error propagates' do
    events = []
    lease = instance_double(
      OsCtld::Container::RunConfiguration::LifecycleLease
    )
    run_conf = instance_double(OsCtld::Container::RunConfiguration)
    failed_netifs = double
    recovered_ct = double(
      state: :running,
      current_state: :stopped,
      run_conf:,
      netifs: failed_netifs,
      pool:,
      id: 'ct1'
    )
    hook = Class.new do
      def self.hook_name = 'post_stop'
    end.new
    hook_error = OsCtld::HookFailed.new(hook, '/hooks/post-stop', 1)
    failed_recovery = described_class.new(recovered_ct)

    allow(recovered_ct).to receive(:inclusively).and_yield
    allow(run_conf).to receive(:acquire_lifecycle_lease) do
      events << :lease
      lease
    end
    allow(run_conf).to receive(:wait_for_lifecycle_leases) { events << :wait }
    allow(failed_netifs).to receive(:each)
    allow(failed_netifs).to receive(:take_down) do
      events << :netifs
      raise 'missing recorded identity'
    end
    allow(lease).to receive(:close) { events << :release }
    allow(recovered_ct).to receive(:stopped) do |expected_run, &block|
      expect(expected_run).to be(run_conf)
      block.call(true)
      events << :stopped
      true
    end
    allow(OsCtld::AppArmor).to receive(:enabled?).and_return(false)
    allow(OsCtld::Hook).to receive(:run) do
      events << :hook
      raise hook_error
    end
    allow(failed_recovery).to receive(:log)
    allow(failed_recovery).to receive(:cleanup_or_taint) do
      events << :cleanup_or_taint
      false
    end

    expect { failed_recovery.recover_state }.to raise_error(hook_error)
    expect(events).to eq(
      %i[lease netifs release wait hook stopped cleanup_or_taint]
    )
  end

  it 'does not touch global state when the old run is already retiring' do
    run_conf = instance_double(OsCtld::Container::RunConfiguration)
    netifs = double
    recovered_ct = double(
      state: :running,
      current_state: :stopped,
      run_conf:,
      netifs:,
      pool:,
      id: 'ct1'
    )
    allow(recovered_ct).to receive(:inclusively).and_yield
    allow(run_conf).to receive(:acquire_lifecycle_lease).and_raise(
      OsCtld::Container::RunConfiguration::LifecycleError,
      'container run is retiring'
    )
    allow(netifs).to receive(:take_down)
    allow(recovered_ct).to receive(:stopped)
    allow(OsCtld::Hook).to receive(:run)
    allow(OsCtld::Eventd).to receive(:report)

    described_class.new(recovered_ct).recover_state

    expect(netifs).not_to have_received(:take_down)
    expect(OsCtld::Hook).not_to have_received(:run)
    expect(recovered_ct).not_to have_received(:stopped)
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles
