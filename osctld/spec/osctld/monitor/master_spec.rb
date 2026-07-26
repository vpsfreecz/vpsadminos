# frozen_string_literal: true

# rubocop:disable RSpec/SubjectStub

require 'osctld/container_control/command'
require 'osctld/monitor'
require 'osctld/monitor/master'

RSpec.describe OsCtld::Monitor::Master do
  subject(:master) { described_class.send(:new) }

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  def build_ct(id:, pool_name: 'tank', user_name: 'alice', group_name: 'default')
    pool = Struct.new(:name).new(pool_name)
    user = Struct.new(:name).new(user_name)
    group = Struct.new(:name).new(group_name)
    run_conf = Struct.new(:init_pid, :run_id).new(nil, 'run-1')
    lifecycle = Struct.new(:observations) do
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

      def finish_state_observation(_run_id, _observer_id)
        false
      end
    end.new([])

    Struct.new(
      :id,
      :pool,
      :user,
      :group,
      :state,
      :run_conf,
      :lifecycle,
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

      def observe_run_state(run_id, value, init_pid: nil)
        return false unless run_conf
        return false unless run_conf.run_id == run_id

        self.state = value
        run_conf.init_pid = init_pid if value == :running
        true
      end
    end.new(id:, pool:, user:, group:, state: :stopped, run_conf:, lifecycle:)
  end

  it 'creates one monitor thread per pool/user/group key' do
    ct1 = build_ct(id: 'ct1')
    ct2 = build_ct(id: 'ct2')
    ct3 = build_ct(id: 'ct3', group_name: 'other')
    allow(Thread).to receive(:new).and_return(instance_double(Thread), instance_double(Thread))
    allow(master).to receive(:update_state)

    master.monitor(ct1)
    master.monitor(ct2)
    master.monitor(ct3)

    expect(Thread).to have_received(:new).twice
    expect(master.instance_variable_get(:@monitors).size).to eq(2)
    expect(master).to have_received(:update_state).with(ct2)
  end

  it 'stops monitoring only after the last container leaves a shared entry' do
    ct1 = build_ct(id: 'ct1')
    ct2 = build_ct(id: 'ct2')
    entry = described_class::Entry.new(instance_double(Thread), 123, %w[ct1 ct2])

    master.instance_variable_get(:@monitors)[master.send(:key, ct1)] = entry
    allow(master).to receive(:graceful_stop)

    master.demonitor(ct1)
    expect(master).not_to have_received(:graceful_stop)

    master.demonitor(ct2)
    expect(master).to have_received(:graceful_stop).with(entry, ct2)
  end

  it 'terminates monitor processes and joins all threads on stop' do
    thread1 = instance_double(Thread, join: nil)
    thread2 = instance_double(Thread, join: nil)
    master.instance_variable_set(:@monitors, {
      'a' => described_class::Entry.new(thread1, 101, []),
      'b' => described_class::Entry.new(thread2, nil, [])
    })
    allow(Process).to receive(:kill)

    master.stop

    expect(Process).to have_received(:kill).with('TERM', 101)
    expect(thread1).to have_received(:join)
    expect(thread2).to have_received(:join)
    expect(master.instance_variable_get(:@monitors)).to be_empty
  end

  it 'updates container state and init pid from container-control state' do
    ct = build_ct(id: 'ct1')
    state = Struct.new(:state, :init_pid).new(:running, 4321)
    state_class = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct); end
    end)
    eventd = stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    allow(state_class).to receive(:run!).with(ct).and_return(state)
    allow(eventd).to receive(:report)
    allow(OsCtld::CGroup).to receive(:get_tree_pids)
      .with('/osctl/test/run-1')
      .and_return([4321])

    master.send(:update_state, ct)

    expect(ct.state).to eq(:running)
    expect(ct.ensure_run_conf.init_pid).to eq(4321)
    expect(eventd).to have_received(:report).with(
      :ct_init_pid,
      pool: 'tank',
      id: 'ct1',
      init_pid: 4321
    )
    expect(ct.lifecycle.observations).to eq([['run-1', :running, 4321, 'state_query']])
  end

  it 'does not clear an existing error state from container-control state' do
    ct = build_ct(id: 'ct1')
    ct.state = :error
    state = Struct.new(:state, :init_pid).new(:running, 4321)
    state_class = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct); end
    end)
    eventd = stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    allow(state_class).to receive(:run!).with(ct).and_return(state)
    allow(eventd).to receive(:report)

    master.send(:update_state, ct)

    expect(ct.state).to eq(:error)
    expect(ct.ensure_run_conf.init_pid).to be_nil
    expect(eventd).not_to have_received(:report)
  end

  it 'logs container-control failures instead of raising from update_state' do
    ct = build_ct(id: 'ct1')
    state_class = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct); end
    end)
    allow(state_class).to receive(:run!).and_raise(OsCtld::ContainerControl::Error, 'boom')

    expect { master.send(:update_state, ct) }.not_to raise_error
    expect(OsCtl::Lib::Logger).to have_received(:log).with(
      :warn,
      '[monitor] Unable to get state of container tank:ct1: boom'
    )
  end
end

# rubocop:enable RSpec/SubjectStub
