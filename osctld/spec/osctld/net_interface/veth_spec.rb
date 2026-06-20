# frozen_string_literal: true

module OsCtld
  module Utils; end
end

require 'ipaddress'
require 'osctld/lock_registry'
require 'osctld/lockable'
require 'osctld/exceptions'
require 'osctld/utils/ip'
require 'osctld/utils/switch_user'
require 'osctld/net_interface'
require 'osctld/net_interface/base'
require 'osctld/net_interface/veth'

RSpec.describe OsCtld::NetInterface::Veth do
  let(:host_boot_id) { '11111111-2222-3333-4444-555555555555' }
  let(:root) { Dir.mktmpdir('osctld-veth') }
  let(:pool) { build_fake_pool(root:) }
  let(:ct) { FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct1', running: false) }
  let(:veth) { described_class.new(ct, 0) }

  before do
    allow(OsCtld::LockRegistry).to receive(:register)
    OsCtl::Lib::Logger.setup(:none)
    stub_const('OsCtld::Eventd', Module.new do
      def self.report(*); end
    end)
    allow(OsCtld::Eventd).to receive(:report)
    allow(described_class).to receive(:current_host_boot_id).and_return(host_boot_id)
    stub_const('OsCtld::ContainerControl', Module.new)
    stub_const('OsCtld::ContainerControl::Commands', Module.new)
    stub_const('OsCtld::ContainerControl::Commands::VethName', Class.new do
      def self.run!(*)
        'vethX'
      end
    end)
    allow(OsCtld::ContainerControl::Commands::VethName).to receive(:run!).and_return('vethX')
    hook_root = root
    OsCtld.define_singleton_method(:hook_src) { |name| File.join(hook_root, 'hooks-src', name) }
    FileUtils.mkdir_p(File.join(root, 'hooks-src'))
    allow(veth).to receive(:syscmd_argv)
    allow(veth).to receive(:host_veth_ifindex) do |_name, expected_kind:|
      expected_kind == 'ifb' ? 20 : 10
    end
    allow(veth).to receive(:host_veth_ifindex!) do |_name, expected_kind:|
      expected_kind == 'ifb' ? 20 : 10
    end
    allow(veth).to receive(:delete_link_by_ifindex)
    ct.netifs = [veth]
    stub_containers_registry([ct])
  end

  after do
    FileUtils.rm_rf(root)
  end

  it 'creates, saves, loads, and round-trips configured IPs' do
    veth.create(
      name: 'eth0',
      hwaddr: '00:11:22:33:44:55',
      tx_queues: 2,
      rx_queues: 3,
      max_tx: 100,
      max_rx: 200,
      enable: true
    )
    veth.add_ip(IPAddress.parse('192.0.2.10'))
    veth.add_ip(IPAddress.parse('2001:db8::10'))

    loaded = described_class.new(ct, 0)
    loaded.load(veth.save)

    expect(loaded.save).to eq(veth.save)
  end

  it 'creates hook symlinks and discovers the host veth when running' do
    ct.running = true
    veth.create(name: 'eth0', hwaddr: nil)

    veth.setup

    expect(File.symlink?(File.join(pool.hook_dir, 'veth', 'up', 'ct1.eth0'))).to be(true)
    expect(File.symlink?(File.join(pool.hook_dir, 'veth', 'down', 'ct1.eth0'))).to be(true)
    expect(veth.veth).to eq('vethX')
    expect(veth.host_link_identity).to eq(['vethX', 10, nil])
    expect(veth.setup_state_changed?).to be(true)
  end

  it 'discovers the IFB belonging to the newly discovered host veth' do
    ct.running = true
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)
    allow(veth).to receive(:host_veth_ifindex).with(
      'ifbvethX',
      expected_kind: 'ifb'
    ).and_return(20)

    veth.setup

    expect(veth.host_link_identity).to eq(['vethX', 10, 20])
    expect(veth).to have_received(:host_veth_ifindex).with(
      'ifbvethX',
      expected_kind: 'ifb'
    )
  end

  it 'does not treat a wrong-kind discovered IFB as absent' do
    ct.running = true
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)
    allow(veth).to receive(:host_veth_ifindex).and_call_original
    allow(veth).to receive(:link_ifindex_by_name).with(
      expected_name: 'ifbvethX',
      expected_kind: 'ifb'
    ).and_raise(
      OsCtld::Utils::Ip::LinkIdentityError,
      'network interface "ifbvethX" has kind "bridge"'
    )

    expect { veth.setup }.to raise_error(
      described_class::InvalidHostLink,
      /kind "bridge"/
    )

    expect(veth.host_link_identity).to eq([nil, nil, nil])
  end

  it 'round-trips a host identity migrated from an old running config' do
    ct.running = true
    old_config = {
      'name' => 'eth0',
      'hwaddr' => nil,
      'max_tx' => 0,
      'max_rx' => 0,
      'enable' => true
    }
    veth.load(old_config)

    veth.setup
    migrated_config = veth.save
    reloaded = described_class.new(ct, 0)
    reloaded.load(migrated_config)

    expect(migrated_config['host_link']).to eq(
      'name' => 'vethX',
      'ifindex' => 10,
      'ifb_ifindex' => nil,
      'boot_id' => host_boot_id,
      'tainted' => false
    )
    expect(reloaded.host_link_identity).to eq(['vethX', 10, nil])
    expect(reloaded.setup_state_changed?).to be(false)
  end

  it 'discards host-link authority retained from an earlier kernel boot' do
    veth.load(
      'name' => 'eth0',
      'hwaddr' => nil,
      'host_link' => {
        'name' => 'veth0',
        'ifindex' => 10,
        'ifb_ifindex' => 20,
        'boot_id' => 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        'tainted' => true
      }
    )

    expect(veth.host_link_identity).to eq([nil, nil, nil])
    expect(veth.host_link_tainted?).to be(false)
    expect(veth.setup_state_changed?).to be(true)
    expect(veth.save).not_to have_key('host_link')
  end

  it 'preserves host-link authority from the current kernel boot' do
    veth.load(
      'name' => 'eth0',
      'hwaddr' => nil,
      'host_link' => {
        'name' => 'veth0',
        'ifindex' => 10,
        'ifb_ifindex' => nil,
        'boot_id' => host_boot_id,
        'tainted' => false
      }
    )

    expect(veth.host_link_identity).to eq(['veth0', 10, nil])
    expect(veth.setup_state_changed?).to be(false)
  end

  it 'adds the current boot ID to a legacy host-link record' do
    veth.load(
      'name' => 'eth0',
      'hwaddr' => nil,
      'host_link' => {
        'name' => 'veth0',
        'ifindex' => 10,
        'ifb_ifindex' => nil,
        'tainted' => false
      }
    )

    expect(veth.save.fetch('host_link')).to include('boot_id' => host_boot_id)
    expect(veth.setup_state_changed?).to be(true)
  end

  it 'does not discover deletion authority while loading imported config' do
    ct.running = true
    veth.load(
      'name' => 'eth0',
      'hwaddr' => nil,
      'max_tx' => 0,
      'max_rx' => 0,
      'enable' => true
    )

    veth.setup(discover_host_links: false)

    expect(OsCtld::ContainerControl::Commands::VethName).not_to have_received(:run!)
    expect(veth.host_link_identity).to eq([nil, nil, nil])
    expect(veth.setup_state_changed?).to be(false)
  end

  it 'owns the host-link registry while validating a standalone up callback' do
    veth.create(name: 'eth0', hwaddr: nil)
    allow(OsCtld::NetInterface).to receive(
      :validate_host_link_claim!
    ).and_wrap_original do |method, **args|
      expect(
        OsCtld::NetInterface::HOST_LINK_REGISTRY_LOCK.owned?
      ).to be(true)
      method.call(**args)
    end

    expect(veth.validate_up_callback('veth0')).to eq(['veth0', 10])
    expect(veth.host_link_identity).to eq([nil, nil, nil])
    expect(OsCtld::NetInterface).to have_received(
      :validate_host_link_claim!
    )
  end

  it 'owns the host-link registry while validating a standalone down callback' do
    veth.load(
      'name' => 'eth0',
      'hwaddr' => nil,
      'host_link' => {
        'name' => 'veth0',
        'ifindex' => 10,
        'ifb_ifindex' => nil,
        'tainted' => false
      }
    )
    allow(OsCtld::NetInterface).to receive(
      :validate_host_link_claim!
    ).and_wrap_original do |method, **args|
      expect(
        OsCtld::NetInterface::HOST_LINK_REGISTRY_LOCK.owned?
      ).to be(true)
      method.call(**args)
    end

    expect(veth.validate_down_callback('veth0')).to eq(
      ['veth0', 10, nil]
    )
    expect(OsCtld::NetInterface).to have_received(
      :validate_host_link_claim!
    )
  end

  it 'renames hook symlinks and reports link state transitions' do
    veth.create(name: 'eth0', hwaddr: nil, enable: false)
    veth.setup

    veth.rename('eth1')
    veth.up('veth0')
    veth.down

    expect(File).not_to exist(File.join(pool.hook_dir, 'veth', 'up', 'ct1.eth0'))
    expect(File.symlink?(File.join(pool.hook_dir, 'veth', 'up', 'ct1.eth1'))).to be(true)
    expect(veth).to have_received(:syscmd_argv).with(%w[ip link set veth0 down], {})
    expect(veth).to have_received(:delete_link_by_ifindex).with(
      10,
      expected_name: 'veth0',
      expected_kind: 'veth'
    )
    expect(OsCtld::Eventd).to have_received(:report).with(
      :ct_netif,
      hash_including(action: :rename, name: 'eth0', new_name: 'eth1')
    )
    expect(OsCtld::Eventd).to have_received(:report).with(
      :ct_netif,
      hash_including(action: :up, veth: 'veth0')
    )
    expect(OsCtld::Eventd).to have_received(:report).with(
      :ct_netif,
      hash_including(action: :down, name: 'eth1')
    )
  end

  it 'persists a new host identity before later up operations can fail' do
    snapshots = []
    allow(ct).to receive(:save_config) { snapshots << veth.save }
    veth.create(name: 'eth0', hwaddr: nil, max_rx: 100)
    allow(veth).to receive(:tc).and_raise(Errno::EPERM)

    expect { veth.up('veth0') }.to raise_error(Errno::EPERM)

    expect(snapshots.map { |cfg| cfg.fetch('host_link')['tainted'] }).to eq([false, true])
    expect(snapshots.first.fetch('host_link')).to include(
      'name' => 'veth0',
      'ifindex' => 10
    )
    expect(ct.state).to eq(:error)
  end

  it 'rejects a host veth already claimed by another container before publication' do
    other_netif = instance_double(described_class, host_link_identity: ['veth0', 10, nil])
    other_ct = FakeObjects::FakeRuntimeContainer.new(
      pool:,
      id: 'ct2',
      netifs: [other_netif]
    )
    stub_containers_registry([ct, other_ct])
    veth.create(name: 'eth0', hwaddr: nil, enable: false)

    expect { veth.up('veth0') }.to raise_error(
      described_class::InvalidHostLink,
      /also claimed by container tank:ct2/
    )

    expect(veth.host_link_identity).to eq([nil, nil, nil])
    expect(veth).not_to have_received(:syscmd_argv)
  end

  it 'rejects a wrong-kind veth-up callback before publication' do
    veth.create(name: 'eth0', hwaddr: nil, enable: false)
    allow(veth).to receive(:host_veth_ifindex!).with(
      'veth0',
      expected_kind: 'veth'
    ).and_raise(
      described_class::InvalidHostLink,
      'network interface "veth0" has kind "bridge"'
    )

    expect { veth.up('veth0') }.to raise_error(
      described_class::InvalidHostLink,
      /kind "bridge"/
    )

    expect(veth.host_link_identity).to eq([nil, nil, nil])
    expect(veth).not_to have_received(:syscmd_argv)
    expect(veth).to have_received(:host_veth_ifindex!).with(
      'veth0',
      expected_kind: 'veth'
    )
  end

  it 'reserves the planned IFB name before creating it' do
    other_netif = instance_double(
      described_class,
      host_link_identity: ['ifbveth0', 30, nil]
    )
    other_ct = FakeObjects::FakeRuntimeContainer.new(
      pool:,
      id: 'ct2',
      netifs: [other_netif]
    )
    stub_containers_registry([ct, other_ct])
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)

    expect { veth.up('veth0') }.to raise_error(
      described_class::InvalidHostLink,
      /also claimed by container tank:ct2/
    )

    expect(veth.host_link_identity).to eq([nil, nil, nil])
    expect(veth).not_to have_received(:syscmd_argv)
  end

  it 'rejects deletion when another container claims the recorded identity' do
    containers = [ct]
    stub_containers_registry(containers)
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')
    other_netif = instance_double(described_class, host_link_identity: ['veth0', 10, nil])
    containers << FakeObjects::FakeRuntimeContainer.new(
      pool:,
      id: 'ct2',
      netifs: [other_netif]
    )

    expect { veth.down }.to raise_error(
      described_class::InvalidHostLink,
      /also claimed by container tank:ct2/
    )

    expect(veth).not_to have_received(:delete_link_by_ifindex)
    expect(veth.host_link_tainted?).to be(true)
  end

  it 'rolls back a newly created IFB whose index conflicts with another owner' do
    other_netif = instance_double(
      described_class,
      host_link_identity: ['veth2', 30, 20]
    )
    other_ct = FakeObjects::FakeRuntimeContainer.new(
      pool:,
      id: 'ct2',
      netifs: [other_netif]
    )
    stub_containers_registry([ct, other_ct])
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)

    expect { veth.up('veth0') }.to raise_error(
      described_class::InvalidHostLink,
      /also claimed by container tank:ct2/
    )

    expect(veth).to have_received(:delete_link_by_ifindex).with(
      20,
      expected_name: 'ifbveth0',
      expected_kind: 'ifb'
    )
    expect(veth.host_link_identity).to eq(['veth0', 10, nil])
    expect(veth.host_link_tainted?).to be(true)
  end

  it 'retains a newly created conflicting IFB when rollback cannot prove deletion' do
    other_netif = instance_double(
      described_class,
      host_link_identity: ['veth2', 30, 20]
    )
    other_ct = FakeObjects::FakeRuntimeContainer.new(
      pool:,
      id: 'ct2',
      netifs: [other_netif]
    )
    stub_containers_registry([ct, other_ct])
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)
    allow(veth).to receive(:delete_link_by_ifindex).with(
      20,
      expected_name: 'ifbveth0',
      expected_kind: 'ifb'
    ).and_raise(Errno::EPERM)

    expect { veth.up('veth0') }.to raise_error(
      described_class::InvalidHostLink,
      /unable to roll back newly created IFB/
    )

    expect(veth.host_link_identity).to eq(['veth0', 10, 20])
    expect(veth.host_link_tainted?).to be(true)
  end

  it 'does not recreate a recorded IFB which disappeared' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)
    veth.up('veth0')
    allow(Dir).to receive(:exist?).with(
      '/sys/devices/virtual/net/ifbveth0'
    ).and_return(false)
    allow(veth).to receive(:ip)

    expect { veth.send(:set_shaper_tx) }.to raise_error(
      described_class::InvalidHostLink,
      /recorded host IFB "ifbveth0".*is absent/
    )

    expect(veth.host_link_identity).to eq(['veth0', 10, 20])
    expect(veth.host_link_tainted?).to be(true)
    expect(veth).not_to have_received(:ip)
  end

  it 'validates the live veth before removing its IFB shaper' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)
    veth.up('veth0')
    allow(veth).to receive(:host_veth_ifindex!).with(
      'veth0',
      expected_kind: 'veth'
    ).and_return(11)
    allow(veth).to receive(:tc)

    expect { veth.send(:unset_shaper_tx) }.to raise_error(
      described_class::InvalidHostLink,
      /changed from ifindex 10 to 11/
    )

    expect(veth.host_link_identity).to eq(['veth0', 10, 20])
    expect(veth.host_link_tainted?).to be(true)
    expect(veth).not_to have_received(:tc)
  end

  it 'validates the live IFB before removing its veth shaper' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)
    veth.up('veth0')
    allow(veth).to receive(:host_veth_ifindex!).with(
      'ifbveth0',
      expected_kind: 'ifb'
    ).and_return(21)
    allow(veth).to receive(:tc)

    expect { veth.send(:unset_shaper_tx) }.to raise_error(
      described_class::InvalidHostLink,
      /changed from ifindex 20 to 21/
    )

    expect(veth.host_link_identity).to eq(['veth0', 10, 20])
    expect(veth.host_link_tainted?).to be(true)
    expect(veth).not_to have_received(:tc)
  end

  it 'validates the live veth before applying runtime shaper changes' do
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')
    allow(veth).to receive(:host_veth_ifindex!).with(
      'veth0',
      expected_kind: 'veth'
    ).and_return(11)
    allow(veth).to receive(:tc)

    expect { veth.set(max_rx: 100) }.to raise_error(
      described_class::InvalidHostLink,
      /changed from ifindex 10 to 11/
    )

    expect(veth.max_rx).to eq(0)
    expect(veth.host_link_identity).to eq(['veth0', 10, nil])
    expect(veth).not_to have_received(:tc)
  end

  it 'taints a partial runtime receive-shaper failure' do
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')
    allow(veth).to receive(:tc) do |args, **|
      next unless args.first(3) == %w[qdisc add root]

      raise Errno::EPERM
    end

    expect { veth.set(max_rx: 100) }.to raise_error(Errno::EPERM)

    expect(veth.max_rx).to eq(100)
    expect(veth.host_link_tainted?).to be(true)
    expect(ct.state).to eq(:error)
  end

  it 'rejects runtime host changes while cleanup is tainted' do
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')
    veth.send(:taint_host_link!)
    allow(veth).to receive(:tc)

    expect { veth.set(max_rx: 100) }.to raise_error(
      described_class::InvalidHostLink,
      /cleanup-tainted/
    )

    expect(veth.max_rx).to eq(0)
    expect(veth).not_to have_received(:tc)
  end

  it 'holds the host-link registry through runtime host changes' do
    change_entered = Queue.new
    release_change = Queue.new
    down_started = Queue.new
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')
    allow(veth).to receive(:tc) do |args, **|
      next unless args == %w[qdisc delete root dev veth0]

      change_entered << true
      release_change.pop
    end

    setter = Thread.new { veth.set(max_rx: 100) }
    change_entered.pop
    down = Thread.new do
      down_started << true
      veth.down('veth0')
    end
    down_started.pop

    expect(down.join(0.05)).to be_nil
    expect(veth.host_link_identity).to eq(['veth0', 10, nil])

    release_change << true
    setter.value
    down.value

    expect(veth.host_link_identity).to eq([nil, nil, nil])
  ensure
    release_change << true if setter&.alive?
    setter&.join
    down&.join
  end

  it 'rejects renaming until the recorded host link is cleaned' do
    veth.create(name: 'eth0', hwaddr: nil)
    veth.setup
    veth.up('veth0')

    expect { veth.rename('eth1') }.to raise_error(
      described_class::InvalidHostLink,
      /complete lifecycle cleanup before renaming/
    )

    expect(veth.name).to eq('eth0')
  end

  it 'does not publish a host identity while recovery owns the registry' do
    holder_ready = Queue.new
    release_holder = Queue.new
    publisher_started = Queue.new
    veth.create(name: 'eth0', hwaddr: nil)

    holder = Thread.new do
      OsCtld::NetInterface.sync_host_link_registry do
        holder_ready << true
        release_holder.pop
      end
    end
    holder_ready.pop

    publisher = Thread.new do
      publisher_started << true
      veth.up('veth0')
    end
    publisher_started.pop

    expect(publisher.join(0.05)).to be_nil
    expect(veth.host_link_identity).to eq([nil, nil, nil])

    release_holder << true
    holder.join
    publisher.join

    expect(veth.host_link_identity).to eq(['veth0', 10, nil])
  ensure
    release_holder << true if holder&.alive?
    holder&.join
    publisher&.join
  end

  it 'does not publish a cleanup taint while recovery owns the registry' do
    holder_ready = Queue.new
    release_holder = Queue.new
    taint_started = Queue.new
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')

    holder = Thread.new do
      OsCtld::NetInterface.sync_host_link_registry do
        holder_ready << true
        release_holder.pop
      end
    end
    holder_ready.pop

    taint = Thread.new do
      taint_started << true
      veth.send(:taint_host_link!)
    end
    taint_started.pop

    expect(taint.join(0.05)).to be_nil
    expect(veth.host_link_tainted?).to be(false)

    release_holder << true
    holder.join
    taint.join

    expect(veth.host_link_tainted?).to be(true)
    expect(ct.state).to eq(:error)
  ensure
    release_holder << true if holder&.alive?
    holder&.join
    taint&.join
  end

  it 'propagates non-ENODEV deletion failures and keeps the recorded identity' do
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')
    allow(veth).to receive(:delete_link_by_ifindex).with(
      10,
      expected_name: 'veth0',
      expected_kind: 'veth'
    ).and_raise(Errno::EPERM)

    expect { veth.down }.to raise_error(Errno::EPERM)

    expect(veth.host_link_identity).to eq(['veth0', 10, nil])
    expect(OsCtld::Eventd).not_to have_received(:report).with(
      :ct_netif,
      hash_including(action: :down)
    )
  end

  it 'retains recorded identity when a proved link disappears before deletion' do
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')
    allow(veth).to receive(:delete_link_by_ifindex).with(
      10,
      expected_name: 'veth0',
      expected_kind: 'veth'
    ).and_raise(Errno::ENODEV)

    expect { veth.down }.to raise_error(
      OsCtld::NetInterface::Veth::InvalidHostLink,
      /disappeared before deletion/
    )

    expect(veth.host_link_identity).to eq(['veth0', 10, nil])
    expect(OsCtld::Eventd).not_to have_received(:report).with(
      :ct_netif,
      hash_including(action: :down, name: 'eth0')
    )
  end

  it 'rejects a caller-selected host link name' do
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')

    expect do
      veth.down('foreign0')
    end.to raise_error(
      OsCtld::NetInterface::Veth::InvalidHostLink,
      'host veth "foreign0" does not match "veth0"'
    )
    expect(veth).not_to have_received(:delete_link_by_ifindex)
  end

  it 'retains state when the recorded veth index has been reassigned' do
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')
    allow(veth).to receive(:delete_link_by_ifindex).with(
      10,
      expected_name: 'veth0',
      expected_kind: 'veth'
    ).and_raise(
      OsCtld::Utils::Ip::LinkIdentityError,
      'recorded veth index now belongs to foreign0'
    )

    expect { veth.down('veth0') }.to raise_error(
      OsCtld::NetInterface::Veth::InvalidHostLink,
      /belongs to foreign0/
    )

    expect(veth.host_link_identity).to eq(['veth0', 10, nil])
  end

  it 'retains veth and IFB state when the recorded IFB index has been reassigned' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)
    veth.up('veth0')
    allow(veth).to receive(:delete_link_by_ifindex).with(
      20,
      expected_name: 'ifbveth0',
      expected_kind: 'ifb'
    ).and_raise(
      OsCtld::Utils::Ip::LinkIdentityError,
      'recorded IFB index now belongs to foreign0'
    )

    expect { veth.down('veth0') }.to raise_error(
      OsCtld::NetInterface::Veth::InvalidHostLink,
      /belongs to foreign0/
    )

    expect(veth.host_link_identity).to eq(['veth0', 10, 20])
    expect(veth).not_to have_received(:delete_link_by_ifindex).with(
      10,
      expected_name: 'veth0',
      expected_kind: 'veth'
    )
  end

  it 'retains only the veth identity after deleting IFB and rejecting a reused veth index' do
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)
    veth.up('veth0')
    deleted_ifindexes = []
    allow(veth).to receive(:delete_link_by_ifindex) do |ifindex, **|
      deleted_ifindexes << ifindex
      next if ifindex == 20

      raise OsCtld::Utils::Ip::LinkIdentityError,
            'recorded veth index now belongs to foreign0'
    end

    expect { veth.down('veth0') }.to raise_error(
      OsCtld::NetInterface::Veth::InvalidHostLink,
      /belongs to foreign0/
    )

    expect(deleted_ifindexes).to eq([20, 10])
    expect(veth.host_link_identity).to eq(['veth0', 10, nil])
  end

  it 'persists partial IFB cleanup before a failed veth deletion and rejects replay after reload' do
    snapshots = []
    allow(ct).to receive(:save_config) { snapshots << veth.save }
    veth.create(name: 'eth0', hwaddr: nil, max_tx: 100)
    veth.up('veth0')
    snapshots.clear
    allow(veth).to receive(:delete_link_by_ifindex) do |ifindex, **|
      next if ifindex == 20

      raise OsCtld::Utils::Ip::LinkIdentityError,
            'recorded veth index now belongs to foreign0'
    end

    expect { veth.down('veth0') }.to raise_error(
      OsCtld::NetInterface::Veth::InvalidHostLink,
      /belongs to foreign0/
    )

    expect(snapshots.map { |cfg| cfg.fetch('host_link') }).to eq(
      [
        {
          'name' => 'veth0',
          'ifindex' => 10,
          'ifb_ifindex' => nil,
          'boot_id' => host_boot_id,
          'tainted' => false
        },
        {
          'name' => 'veth0',
          'ifindex' => 10,
          'ifb_ifindex' => nil,
          'boot_id' => host_boot_id,
          'tainted' => true
        }
      ]
    )
    expect(ct.state).to eq(:error)

    reloaded = described_class.new(ct, 0)
    reloaded.load(snapshots.last)
    allow(reloaded).to receive(:host_veth_ifindex!).and_return(10)

    expect { reloaded.up('veth0') }.to raise_error(
      OsCtld::NetInterface::Veth::InvalidHostLink,
      /cleanup-tainted/
    )
    expect(reloaded.host_link_identity).to eq(['veth0', 10, nil])
  end

  it 'persists final removal by clearing the durable host-link identity' do
    snapshots = []
    allow(ct).to receive(:save_config) { snapshots << veth.save }
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')
    snapshots.clear

    expect(veth.down('veth0')).to eq('veth0')

    expect(snapshots).to match([hash_not_including('host_link')])
    expect(veth.host_link_identity).to eq([nil, nil, nil])
    expect(veth.host_link_tainted?).to be(false)
  end

  [
    [
      'absent veth',
      { 'name' => 'veth0', 'ifindex' => 10, 'ifb_ifindex' => nil, 'tainted' => false },
      10,
      'recorded veth is absent'
    ],
    [
      'reused veth',
      { 'name' => 'veth0', 'ifindex' => 10, 'ifb_ifindex' => nil, 'tainted' => false },
      10,
      'recorded veth now belongs to foreign0'
    ],
    [
      'reused IFB',
      { 'name' => 'veth0', 'ifindex' => 10, 'ifb_ifindex' => 20, 'tainted' => false },
      20,
      'recorded IFB now belongs to foreign0'
    ]
  ].each do |description, host_link, failing_ifindex, message|
    it "retains and taints a reloaded identity for #{description}" do
      snapshots = []
      allow(ct).to receive(:save_config) { snapshots << veth.save }
      veth.load(
        'name' => 'eth0',
        'hwaddr' => nil,
        'max_tx' => host_link['ifb_ifindex'] ? 100 : 0,
        'host_link' => host_link
      )
      allow(veth).to receive(:delete_link_by_ifindex) do |ifindex, **|
        raise OsCtld::Utils::Ip::LinkIdentityError, message if ifindex == failing_ifindex
      end

      expect { veth.down('veth0') }.to raise_error(
        OsCtld::NetInterface::Veth::InvalidHostLink,
        message
      )

      expected_ifb = failing_ifindex == 20 ? 20 : nil
      expect(veth.host_link_identity).to eq(['veth0', 10, expected_ifb])
      expect(veth.host_link_tainted?).to be(true)
      expect(ct.state).to eq(:error)
      expect(snapshots.last.fetch('host_link')).to include(
        'name' => 'veth0',
        'ifindex' => 10,
        'ifb_ifindex' => expected_ifb,
        'tainted' => true
      )
    end
  end

  it 'rejects a missing recorded veth index without deleting any link' do
    veth.create(name: 'eth0', hwaddr: nil)
    veth.up('veth0')
    veth.instance_variable_set('@veth_ifindex', nil)

    expect { veth.down('veth0') }.to raise_error(
      OsCtld::NetInterface::Veth::InvalidHostLink,
      'host veth "veth0" has no valid recorded ifindex'
    )
    expect(veth).not_to have_received(:delete_link_by_ifindex)
  end

  it 'tracks IPs, supports prefix-less lookup, and isolates duplicated state' do
    veth.create(name: 'eth0', hwaddr: nil)
    ipv4 = IPAddress.parse('192.0.2.10/24')
    ipv6 = IPAddress.parse('2001:db8::10/64')
    veth.add_ip(ipv4)
    veth.add_ip(ipv6)

    expect(veth.active_ip_versions).to eq([4, 6])
    expect(veth.has_ip?(IPAddress.parse('192.0.2.10/24'))).to be(true)
    expect(veth.has_ip?(IPAddress.parse('192.0.2.10'), prefix: false)).to be(true)

    copy = veth.dup(FakeObjects::FakeRuntimeContainer.new(pool:, id: 'ct2'))
    copy.add_ip(IPAddress.parse('192.0.2.11/24'))
    copy.del_ip(ipv4)
    copy.del_all_ips(6)

    expect(veth.ips(4).map(&:to_string)).to eq(['192.0.2.10/24'])
    expect(veth.ips(6).map(&:to_string)).to eq(['2001:db8::10/64'])
    expect(copy.veth).to be_nil
  end
end
