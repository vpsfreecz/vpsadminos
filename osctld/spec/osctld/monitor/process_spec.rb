# frozen_string_literal: true

require 'stringio'
require 'osctld/container_control/command'
require 'osctld/container_control/commands/state'
require 'osctld/monitor'
require 'osctld/monitor/process'

RSpec.describe OsCtld::Monitor::Process do
  subject(:process) { described_class.new(pool, user, group, stdout) }

  let(:pool) { Struct.new(:name).new('tank') }
  let(:user) { Struct.new(:name, :sysusername, :ugid, :homedir).new('alice', 'alice', 1234, '/home/alice') }
  let(:group) do
    Struct.new(:name) do
      def full_cgroup_path(_user)
        '/osctl/pool.tank/group.default/user.alice'
      end
    end.new('default')
  end
  let(:stdout) { StringIO.new }

  around do |example|
    old_child_status = $?
    example.run
  ensure
    $CHILD_STATUS = old_child_status
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  def build_ct(id: 'ct1')
    run_conf = Struct.new(:init_pid, :aborted).new(nil, false)
    mounts = Struct.new(:pruned) do
      def prune
        self.pruned = true
      end
    end.new(false)

    Struct.new(
      :id, :pool, :user, :group, :state, :run_conf, :mounts, :lxc_home,
      keyword_init: true
    ) do
      def ident
        "#{pool.name}:#{id}"
      end

      def ensure_run_conf
        run_conf
      end

      def init_pid
        run_conf.init_pid
      end

      def set_init_pid(pid)
        run_conf.init_pid = pid
      end
    end.new(
      id:,
      pool:,
      user:,
      group:,
      state: :stopped,
      run_conf:,
      mounts:,
      lxc_home: '/var/lib/lxc/alice'
    )
  end

  it 'parses container state-change lines' do
    expect(
      process.send(:parse, "'ct1' changed state to [RUNNING]\n")
    ).to eq(pool: 'tank', ctid: 'ct1', state: :running)
  end

  it 'logs exit lines and unrecognized lines without returning changes' do
    expect(process.send(:parse, "'ct1' exited with status [0]\n")).to be_nil
    expect(process.send(:parse, "garbage\n")).to be_nil
    expect(OsCtl::Lib::Logger).to have_received(:log).with(
      :warn,
      "[monitor] Line from lxc-monitor not recognized: 'garbage\n'"
    )
  end

  it 'updates running containers, emits events, and runs post-start hooks' do
    ct = build_ct
    db = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    eventd = stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    hook = stub_const('OsCtld::Hook', Class.new do
      def self.run(*, **); end
    end)
    state_class = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct); end
    end)
    allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
    allow(eventd).to receive(:report)
    allow(hook).to receive(:run)
    allow(state_class).to receive(:run!).with(ct).and_return(
      Struct.new(:id, :state, :init_pid).new('ct1', :running, 5678)
    )

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :running)

    expect(ct.state).to eq(:running)
    expect(ct.ensure_run_conf.init_pid).to eq(5678)
    expect(eventd).to have_received(:report).with(:state, pool: 'tank', id: 'ct1', state: :running)
    expect(eventd).to have_received(:report).with(:ct_init_pid, pool: 'tank', id: 'ct1', init_pid: 5678)
    expect(hook).to have_received(:run).with(ct, :post_start, init_pid: 5678)
  end

  it 'keeps monitoring when a short-lived init exits before it can be pinned' do
    ct = build_ct
    db = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    eventd = stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    hook = stub_const('OsCtld::Hook', Class.new do
      def self.run(*, **); end
    end)
    state_class = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct); end
    end)
    allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
    allow(eventd).to receive(:report)
    allow(hook).to receive(:run)
    allow(state_class).to receive(:run!).with(ct).and_return(
      Struct.new(:id, :state, :init_pid).new('ct1', :running, 5678)
    )
    allow(ct).to receive(:set_init_pid).with(5678).and_raise(Errno::ESRCH)

    expect do
      process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :running)
    end.not_to raise_error

    expect(ct.state).to eq(:running)
    expect(eventd).to have_received(:report).with(:state, pool: 'tank', id: 'ct1', state: :running)
    expect(eventd).not_to have_received(:report).with(:ct_init_pid, any_args)
    expect(hook).to have_received(:run).with(ct, :post_start, init_pid: nil)
  end

  it 'does not clear an existing error state from lxc-monitor events' do
    ct = build_ct
    ct.state = :error
    db = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    eventd = stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    hook = stub_const('OsCtld::Hook', Class.new do
      def self.run(*, **); end
    end)
    state_class = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct); end
    end)
    allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
    allow(eventd).to receive(:report)
    allow(hook).to receive(:run)
    allow(state_class).to receive(:run!)

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :running)

    expect(ct.state).to eq(:error)
    expect(ct.ensure_run_conf.init_pid).to be_nil
    expect(eventd).not_to have_received(:report)
    expect(hook).not_to have_received(:run)
    expect(state_class).not_to have_received(:run!)
  end

  it 'marks aborting containers as aborted and prunes mounts on aborted and stopped transitions' do
    ct = build_ct
    db = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    eventd = stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    allow(db).to receive(:find).and_return(ct)
    allow(eventd).to receive(:report)

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :aborting)
    expect(ct.ensure_run_conf.aborted).to be(true)

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :aborted)
    expect(ct.mounts.pruned).to be(true)
  end

  it 'runs on-stop hooks when containers begin stopping' do
    ct = build_ct
    db = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    eventd = stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    hook = stub_const('OsCtld::Hook', Class.new do
      def self.run(*, **); end
    end)
    allow(db).to receive(:find).and_return(ct)
    allow(eventd).to receive(:report)
    allow(hook).to receive(:run)

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :stopping)

    expect(hook).to have_received(:run).with(ct, :on_stop)
  end

  it 'warns when state updates refer to missing containers' do
    db = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    allow(db).to receive(:find).with('missing', 'tank').and_return(nil)

    expect do
      process.send(:update_state, pool: 'tank', ctid: 'missing', state: :running)
    end.not_to raise_error

    expect(OsCtl::Lib::Logger).to have_received(:log).with(
      :warn,
      '[monitor] Container tank:missing not found'
    )
  end

  it 'spawns lxc-monitor under the monitor cgroup' do
    ct = build_ct
    out_r = instance_double(IO, close: nil)
    out_w = instance_double(IO, close: nil)
    cgroup = stub_const('OsCtld::CGroup', Class.new do
      def self.mkpath_all(_path); end
    end)
    switch_user = stub_const('OsCtld::SwitchUser', Class.new do
      def self.switch_to(*); end
    end)
    allow(IO).to receive(:pipe).and_return([out_r, out_w])
    allow(cgroup).to receive(:mkpath_all)
    allow($stdout).to receive(:reopen).with(out_w)
    allow(Process).to receive(:exec)
    allow(switch_user).to receive(:switch_to)
    allow(Process).to receive(:fork) do |&block|
      block.call
      321
    end

    pid, io = described_class.spawn(ct)

    expect(pid).to eq(321)
    expect(io).to equal(out_r)
    expect(cgroup).to have_received(:mkpath_all).with(
      ['', 'osctl', 'pool.tank', 'group.default', 'user.alice', 'monitor']
    )
    expect(switch_user).to have_received(:switch_to).with(
      'alice',
      1234,
      '/home/alice',
      '/osctl/pool.tank/group.default/user.alice/monitor'
    )
    expect(Process).to have_received(:exec).with('lxc-monitor', '-P', '/var/lib/lxc/alice', '-n', '.*')
    expect(out_w).to have_received(:close)
  end

  it 'stops lxc-monitord through the monitor cgroup' do
    ct = build_ct
    switch_user = stub_const('OsCtld::SwitchUser', Class.new do
      def self.switch_to(*); end
    end)
    allow(switch_user).to receive(:switch_to)
    allow(Process).to receive(:exec)
    allow(Process).to receive(:fork) do |&block|
      block.call
      654
    end
    allow(Process).to receive(:wait2).with(654).and_return([654, build_wait_status(0)])

    described_class.stop_monitord(ct)

    expect(switch_user).to have_received(:switch_to).with(
      'alice',
      1234,
      '/home/alice',
      '/osctl/pool.tank/group.default/user.alice/monitor'
    )
    expect(Process).to have_received(:exec).with('lxc-monitor', '-P', '/var/lib/lxc/alice', '--quit')
    expect(OsCtl::Lib::Logger).to have_received(:log).with(:info, '[monitor] Stopped lxc-monitord')
  end
end
