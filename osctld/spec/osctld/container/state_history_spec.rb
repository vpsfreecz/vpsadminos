# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable

require 'osctld/exceptions'
require 'osctld/attributes'
require 'osctld/auto_start/config'
require 'osctld/utils/switch_user'
require 'osctld/container/adaptor'
require 'osctld/container/raw_configs'
require 'osctld/container/impermanence'
require 'osctld/container/start_menu'
require 'osctld/container'
require 'osctld/pool'
require 'osctld/command'
require 'osctld/user_control/command'
require 'osctld/user_control/commands/ct_pre_start'
require 'osctld/hook'

RSpec.describe OsCtld::Container, '#state=' do
  around do |example|
    with_tmpdir do |dir|
      @dir = dir
      boot_id_path = File.join(dir, 'boot-id')
      path = File.join(dir, 'history.json')
      boot_id = '00000000-0000-4000-8000-000000000001'
      File.write(boot_id_path, boot_id)
      File.write(path, JSON.generate(schema_version: 1, boot_id:, next_sequence: 1, dropped_events: 0, entries: [], events: []))
      @history = OsCtld::ContainerStateHistory.new(path:, boot_id_path:)
      @history.load
      example.run
    end
  end

  before do
    OsCtld::Container::Adaptor.instance_variable_set(:@adaptors, nil)
    stub_container_runtime_classes(run_configuration_class: build_fake_run_configuration_class)
    allow(OsCtld::ContainerStateHistory).to receive(:instance).and_return(@history)
    allow(OsCtl::Lib::Logger).to receive(:log)
    allow(File).to receive(:chown).and_return(0)
  end

  it 'records actual running state and keeps it across later stopped/aborted states' do
    ct = build_container_fixture(root: @dir)
    ct.state = :starting
    ct.state = :aborted
    expect(@history.export(view: 'ever_running')[:entries]).to eq([])

    ct.state = :running
    saved = @history.export(view: 'ever_running')[:entries]
    ct.state = :stopping
    ct.state = :stopped
    ct.state = :running

    expect(@history.export(view: 'ever_running')[:entries]).to eq(saved)
    expect(saved).to contain_exactly(
      pool: 'tank', id: 'ct1', first_running_boottime_seconds: a_kind_of(Numeric)
    )
  end

  it 'does not record failed pre-start hooks even after scheduler fulfillment' do
    ct = build_container_fixture(root: @dir)
    ct.configure('almalinux', '9', 'x86_64')
    pool = ct.pool
    pool.define_singleton_method(:fulfil_autostart) { |_ct| nil }
    pool.define_singleton_method(:fulfil_reboot) { |_ct| nil }
    allow(pool).to receive(:fulfil_autostart)
    run_conf = Object.new
    def run_conf.mount(force:); end
    ct.instance_variable_set(:@run_conf, run_conf)
    ct.devices.define_singleton_method(:apply) { nil }
    ct.mounts.shared_dir.define_singleton_method(:create) { nil }
    allow(ct).to receive(:setup_start_menu)
    stub_const('OsCtld::AppArmor', Class.new do
      def self.enabled? = false
    end)
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
    allow(OsCtld::DB::Containers).to receive(:find).and_return(ct)
    stub_const('OsCtld::Commands::Container::CGParamApply', Class.new)
    allow(OsCtld::BpfFs).to receive(:setup_ct)
    hook = Class.new do
      def self.hook_name = :pre_start
    end.new
    allow(OsCtld::Hook).to receive(:run).with(ct, :pre_start).and_raise(
      OsCtld::HookFailed.new(hook, '/pre-start', 1)
    )
    command = OsCtld::UserControl::Commands::CtPreStart.new(ct.user, id: ct.id, pool: pool.name)
    allow(command).to receive(:call_cmd).and_return(status: true)

    expect(command.execute).to include(status: false)
    expect(pool).to have_received(:fulfil_autostart).with(ct)
    expect(@history.export(view: 'ever_running')[:entries]).to eq([])
  end

  it 'records an accepted running transition from staged state' do
    ct = build_container_fixture(root: @dir, staged: true)
    ct.configure('almalinux', '9', 'x86_64')
    ct.state = :running

    expect(@history.export(view: 'ever_running')[:entries].map { |entry| entry[:id] }).to eq(['ct1'])
    expect(ct.state).to eq(:running)
  end

  it 'keeps container control working after persistence fails' do
    ct = build_container_fixture(root: @dir)
    allow(File).to receive(:rename).and_raise(Errno::ENOSPC)

    expect { ct.state = :running }.not_to raise_error
    expect(ct.state).to eq(:running)
    expect(@history.export).to include(available: false, reason: 'persistence_failed')
    expect { ct.state = :stopped }.not_to raise_error
  end

  it 'reconstructs every still-running container from actual state' do
    state = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct)
        Struct.new(:state, :init_pid).new(:running, nil)
      end
    end)
    allow(state).to receive(:run!).and_call_original
    first = build_container_fixture(root: @dir, id: 'first')
    second = build_container_fixture(root: @dir, id: 'second', pool: first.pool, user: first.user, group: first.group)

    pool = OsCtld::Pool.new('tank', 'tank')
    pool.send(:reconcile_container_state_history, first)
    pool.send(:reconcile_container_state_history, second)

    expect(state).to have_received(:run!).with(first)
    expect(state).to have_received(:run!).with(second)
    expect(@history.export(view: 'ever_running')[:entries].map { |entry| entry[:id] }).to eq(%w[first second])
  end

  %i[error staged].each do |quarantine|
    it "records running without clearing persisted #{quarantine} state" do
      ct = build_container_fixture(root: @dir, staged: quarantine == :staged)
      ct.state = :error if quarantine == :error
      allow(ct).to receive(:save_config)
      stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
        def self.run!(_ct)
          Struct.new(:state, :init_pid).new(:running, 123)
        end
      end)
      pool = OsCtld::Pool.new('tank', 'tank')

      expect(pool.send(:reconcile_container_state_history, ct)).to be(false)
      expect(ct.state).to eq(quarantine)
      expect(ct).not_to have_received(:save_config)
      expect(@history.export(view: 'ever_running')[:entries].map { |entry| entry[:id] }).to eq(['ct1'])
    end
  end

  it 'keeps history and quarantine intact when the reconstruction query fails' do
    ct = build_container_fixture(root: @dir)
    ct.state = :error
    stub_const('OsCtld::ContainerControl::Error', Class.new(StandardError))
    state = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct); end
    end)
    allow(state).to receive(:run!).and_raise(OsCtld::ContainerControl::Error, 'query failed')
    pool = OsCtld::Pool.new('tank', 'tank')

    expect(pool.send(:reconcile_container_state_history, ct)).to be(false)
    expect(ct.state).to eq(:error)
    expect(@history.export(view: 'ever_running')[:entries]).to eq([])
    expect(OsCtl::Lib::Logger).to have_received(:log).with(
      :warn, '[container_state_history] Unable to query container tank:ct1: query failed'
    )
  end

  it 'records effective staged completion and ignores refused assignments' do
    ct = build_container_fixture(root: @dir, staged: true)
    ct.configure('almalinux', '9', 'x86_64')
    ct.state = :starting
    expect(@history.export[:events]).to eq([])
    ct.state = :complete

    expect(ct.state).to eq(:stopped)
    expect(@history.export[:events]).to contain_exactly(include(kind: 'state', state: 'stopped'))
  end

  it 'records initial real publication but not constructor or clone placeholders' do
    require 'osctld/db/containers'
    ct = build_container_fixture(root: @dir)
    ct.clone
    expect(@history.export[:events]).to eq([])
    stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    OsCtld::DB::Containers.add(ct)

    expect(@history.export[:events]).to contain_exactly(include(kind: 'state', state: 'unknown'))
  ensure
    OsCtld::DB::Containers.instance.instance_variable_set(:@objects, [])
  end

  it 'records guarded error observations without clearing management state' do
    ct = build_container_fixture(root: @dir)
    ct.state = :error
    expect(ct.accepts_observed_state?(:running)).to be(false)
    expect(ct.state).to eq(:error)
    expect(@history.export[:events]).to contain_exactly(
      include(kind: 'state', state: 'error'), include(kind: 'observation', state: 'running')
    )
    ct.assign_observed_state(:running)
    expect(ct.state).to eq(:running)
    expect(@history.export[:events].last).to include(kind: 'state', state: 'running')
  end

  it 'records a refused staged LXC sample as an observation only' do
    ct = build_container_fixture(root: @dir, staged: true)
    ct.assign_observed_state(:stopped)

    expect(ct.state).to eq(:staged)
    expect(@history.export[:events]).to contain_exactly(include(kind: 'observation', state: 'stopped'))
  end

  it 'orders accepted same-container assignments and recording under one lock' do
    ct = build_container_fixture(root: @dir)
    threads = 20.times.map { |i| Thread.new { ct.state = :"s#{i}" } }
    threads.each(&:join)

    expect(@history.export[:events].size).to eq(20)
    expect(@history.export[:events].last[:state]).to eq(ct.state.to_s)
  end

  it 'keeps synthetic recovery notifications out of the timeline' do
    require 'osctld/container/recovery'
    ct = build_container_fixture(root: @dir)
    ct.state = :running
    state = stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
      def self.run!(_ct)
        Struct.new(:state, :init_pid).new(:stopped, nil)
      end
    end)
    allow(state).to receive(:run!).and_call_original
    stub_const('OsCtld::Eventd', Class.new do
      def self.report(*); end
    end)
    allow(OsCtld::Eventd).to receive(:report)
    stub_const('OsCtld::AppArmor', Class.new do
      def self.enabled? = false
    end)
    allow(OsCtld::Hook).to receive(:run)
    allow(ct).to receive(:stopped)
    recovery = OsCtld::Container::Recovery.new(ct)
    allow(recovery).to receive(:take_down_netifs)
    recovery.recover_state

    expect(OsCtld::Eventd).to have_received(:report).with(:state, pool: 'tank', id: 'ct1', state: :aborting)
    expect(@history.export[:events].map { |event| event[:state] }).to eq(%w[running stopped])
  end
end

# rubocop:enable RSpec/InstanceVariable
