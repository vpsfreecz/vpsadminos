# frozen_string_literal: true

require 'stringio'
require 'osctld/container_control/command'
require 'osctld/container_control/commands/state'
require 'osctld/monitor'
require 'osctld/monitor/process'

RSpec.describe OsCtld::Monitor::Process do
  subject(:process) { described_class.new(pool, user, group, stdout) }

  let(:pool) do
    Struct.new(:name) do
      def fulfil_autostart(_ct); end

      def fulfil_reboot(_ct); end
    end.new('tank')
  end
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
    stub_daemon
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  def build_ct(id: 'ct1')
    run_conf = Struct.new(:init_pid, :aborted, :run_id) do
      def mark_aborted
        self.aborted = true
      end
    end.new(nil, false, 'run-1')
    lifecycle = Struct.new(:observations, :reported_state) do
      def active_run_id
        'run-1'
      end

      def run(_run_id)
        { 'resources' => { 'cgroup_root' => '/osctl/test/run-1' } }
      end

      def execution_run?(_run_id)
        false
      end

      def begin_state_observation(run_id, state, source:, init_pid: nil)
        observations << [run_id, state, init_pid, source]
        'observer-1'
      end

      def state_observation_current?(_run_id, _observer_id)
        true
      end

      def claim_state_effects(_run_id, _observer_id, state)
        return false if reported_state == state

        self.reported_state = state
        true
      end

      def complete_running_effects(*, **)
        true
      end

      def finish_state_observation(_run_id, _observer_id)
        false
      end
    end.new([], nil)
    mounts = Struct.new(:pruned) do
      def prune
        self.pruned = true
      end
    end.new(false)

    Struct.new(
      :id, :pool, :user, :group, :config_state, :runtime_state, :run_conf,
      :mounts, :lxc_home, :lifecycle,
      keyword_init: true
    ) do
      def ident
        "#{pool.name}:#{id}"
      end

      def ensure_run_conf
        run_conf
      end

      def get_past_run_conf
        nil
      end

      def init_pid
        run_conf.init_pid
      end

      def observe_run_state(run_id, value, init_pid: nil)
        return false unless run_conf
        return false unless run_conf.run_id == run_id

        self.runtime_state = value
        run_conf.init_pid = init_pid if value == :running
        run_conf.mark_aborted if %i[aborting aborted].include?(value)
        true
      end
    end.new(
      id:,
      pool:,
      user:,
      group:,
      config_state: :ready,
      runtime_state: :stopped,
      run_conf:,
      mounts:,
      lxc_home: '/var/lib/lxc/alice',
      lifecycle:
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
    allow(pool).to receive(:fulfil_autostart)
    allow(pool).to receive(:fulfil_reboot)
    allow(state_class).to receive(:run!).with(ct).and_return(
      Struct.new(:id, :state, :init_pid).new('ct1', :running, 5678)
    )
    allow(OsCtld::CGroup).to receive(:get_tree_pids)
      .with('/osctl/test/run-1')
      .and_return([5678])

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :running)
    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :running)

    expect(ct.runtime_state).to eq(:running)
    expect(ct.ensure_run_conf.init_pid).to eq(5678)
    expect(eventd).to have_received(:report)
      .with(
        :runtime_state,
        pool: 'tank',
        id: 'ct1',
        runtime_state: :running,
        runtime_state_error: nil
      )
      .once
    expect(eventd).to have_received(:report)
      .with(:ct_init_pid, pool: 'tank', id: 'ct1', init_pid: 5678)
      .once
    expect(hook).to have_received(:run)
      .with(ct, :post_start, init_pid: 5678)
      .once
    expect(pool).to have_received(:fulfil_autostart).with(ct).once
    expect(pool).to have_received(:fulfil_reboot).with(ct).once
    expect(ct.lifecycle.observations).to eq(
      [
        ['run-1', :running, 5678, 'monitor'],
        ['run-1', :running, 5678, 'monitor']
      ]
    )
  end

  it 'tracks transient execution state without publishing container state' do
    ct = build_ct
    allow(ct.lifecycle).to receive(:execution_run?).and_return(true)
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
    allow(db).to receive(:find).and_return(ct)
    allow(eventd).to receive(:report)
    allow(hook).to receive(:run)
    allow(state_class).to receive(:run!).and_return(
      Struct.new(:state, :init_pid).new(:running, 5678)
    )
    allow(OsCtld::CGroup).to receive(:get_tree_pids)
      .with('/osctl/test/run-1')
      .and_return([5678])

    process.send(
      :update_state,
      pool: 'tank',
      ctid: 'ct1',
      state: :running
    )

    expect(ct.runtime_state).to eq(:stopped)
    expect(eventd).not_to have_received(:report)
    expect(hook).not_to have_received(:run)
    expect(ct.lifecycle.observations).to eq(
      [['run-1', :running, 5678, 'monitor']]
    )
  end

  it 'keeps a configuration error while applying lxc-monitor events' do
    ct = build_ct
    ct.config_state = :error
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
      Struct.new(:state, :init_pid).new(:running, 5678)
    )
    allow(OsCtld::CGroup).to receive(:get_tree_pids)
      .with('/osctl/test/run-1')
      .and_return([5678])

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :running)

    expect(ct.config_state).to eq(:error)
    expect(ct.runtime_state).to eq(:running)
    expect(ct.ensure_run_conf.init_pid).to eq(5678)
    expect(eventd).to have_received(:report).with(
      :runtime_state,
      pool: 'tank',
      id: 'ct1',
      runtime_state: :running,
      runtime_state_error: nil
    )
    expect(hook).to have_received(:run).with(ct, :post_start, init_pid: 5678)
    expect(state_class).to have_received(:run!).once
  end

  it 'marks an exact aborting generation without pruning on terminal monitor events' do
    ct = build_ct
    db = stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    eventd = stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    allow(db).to receive(:find).and_return(ct)
    allow(eventd).to receive(:report)
    state_class = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct); end
    end)
    allow(state_class).to receive(:run!).with(ct).and_return(
      Struct.new(:state, :init_pid).new(:aborting, 5678)
    )
    allow(OsCtld::CGroup).to receive(:get_tree_pids)
      .with('/osctl/test/run-1')
      .and_return([5678])

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :aborting)
    expect(ct.ensure_run_conf.aborted).to be(true)

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :aborted)
    expect(ct.mounts.pruned).to be(false)
    expect(state_class).to have_received(:run!).once
  end

  it 'does not run generation-unsafe on-stop hooks from monitor events' do
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
    state_class = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct); end
    end)
    allow(state_class).to receive(:run!).with(ct).and_return(
      Struct.new(:state, :init_pid).new(:stopping, 5678)
    )
    allow(OsCtld::CGroup).to receive(:get_tree_pids)
      .with('/osctl/test/run-1')
      .and_return([5678])

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :stopping)

    expect(hook).not_to have_received(:run)
  end

  it 'does not apply a state observation after the active run changes' do
    ct = build_ct
    original_run = ct.run_conf
    replacement = original_run.class.new(nil, false, 'run-2')
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
    allow(db).to receive(:find).and_return(ct)
    allow(eventd).to receive(:report)
    allow(hook).to receive(:run)
    allow(state_class).to receive(:run!).and_return(
      Struct.new(:state, :init_pid).new(:stopping, 5678)
    )
    allow(OsCtld::CGroup).to receive(:get_tree_pids)
      .with('/osctl/test/run-1')
      .and_return([5678])
    allow(ct.lifecycle).to receive(:begin_state_observation) do
      ct.run_conf = replacement
      'observer-1'
    end
    allow(ct.lifecycle).to receive(:finish_state_observation).and_return(false)

    process.send(:update_state, pool: 'tank', ctid: 'ct1', state: :stopping)

    expect(ct.runtime_state).to eq(:stopped)
    expect(hook).not_to have_received(:run)
    expect(eventd).not_to have_received(:report)
    expect(ct.mounts.pruned).to be(false)
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
