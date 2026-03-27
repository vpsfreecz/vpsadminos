# frozen_string_literal: true

require 'osctld/continuous_executor'
require 'osctld/progress_tracker'
require 'osctld/auto_stop/plan'

RSpec.describe OsCtld::AutoStop::Plan do
  def autostart_plan_double
    instance_double(
      Class.new do
        def clear_ct(_ct); end
      end,
      clear_ct: nil
    )
  end

  def client_handler_double
    instance_double(
      Class.new do
        def send_update(_msg); end
      end,
      send_update: nil
    )
  end

  def stub_commands
    stub_const('OsCtld::Commands', Module.new)
    stub_const('OsCtld::Commands::Container', Module.new)
    stub_const('OsCtld::Commands::Container::Stop', Class.new do
      def self.run(*)
        { status: true }
      end
    end)
    stub_const('OsCtld::Commands::Container::Delete', Class.new do
      def self.run(*)
        { status: true }
      end
    end)
    allow(OsCtld::Commands::Container::Stop).to receive(:run).and_return(status: true)
    allow(OsCtld::Commands::Container::Delete).to receive(:run).and_return(status: true)
  end

  def stub_cpu_scheduler(sequential: false)
    stub_const('OsCtld::CpuScheduler', Module.new do
      def self.use_sequential_start_stop?
        false
      end
    end)
    allow(OsCtld::CpuScheduler).to receive(:use_sequential_start_stop?).and_return(sequential)
  end

  def build_ct(pool:, id:, autostart: nil, run_conf: nil, ephemeral: false)
    FakeObjects::FakeRuntimeContainer.new(
      pool:,
      id:,
      autostart:,
      run_conf:,
      ephemeral:
    )
  end

  let(:pool) do
    Struct.new(:name, :parallel_stop, :autostart_plan).new(
      'tank',
      3,
      autostart_plan_double
    )
  end
  let(:executor) { RuntimePolicyHelpers::RecordingExecutor.new }

  before do
    OsCtl::Lib::Logger.setup(:none)
    stub_daemon(debug: false)
    stub_cpu_scheduler
    stub_commands
    allow(OsCtld::ContinuousExecutor).to receive(:new).and_return(executor)
  end

  it 'sorts auto-stop queue by reversed autostart priority when sequential scheduling is disabled' do
    no_autostart = build_ct(pool:, id: 'none')
    low = build_ct(
      pool:,
      id: 'low',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 5, delay: 0, ct_id: 'low')
    )
    high = build_ct(
      pool:,
      id: 'high',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 10, delay: 0, ct_id: 'high')
    )
    stub_containers_registry([high, no_autostart, low])

    described_class.new(pool).start

    expect(executor.enqueued.map(&:id)).to eq(%w[none high low])
  end

  it 'sorts by run state, package, and reversed priority when sequential scheduling is enabled' do
    package1 = build_ct(
      pool:,
      id: 'package1',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 5, delay: 0, ct_id: 'package1'),
      run_conf: Struct.new(:cpu_package).new(1)
    )
    package0 = build_ct(
      pool:,
      id: 'package0',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 10, delay: 0, ct_id: 'package0'),
      run_conf: Struct.new(:cpu_package).new(0)
    )
    stopped = build_ct(pool:, id: 'stopped', autostart: nil, run_conf: nil)

    stub_cpu_scheduler(sequential: true)
    stub_containers_registry([stopped, package0, package1])

    described_class.new(pool).start

    expect(executor.enqueued.map(&:id)).to eq(%w[package1 package0 stopped])
  end

  it 'stops persistent containers and clears their autostart state' do
    ct = build_ct(pool:, id: 'persist')
    stub_containers_registry([ct])

    described_class.new(pool).start(message: 'bye')
    executor.enqueued.first.send(:exec)

    expect(OsCtld::Commands::Container::Stop).to have_received(:run).with(
      pool: 'tank',
      id: 'persist',
      progress: false,
      manipulation_lock: 'ignore',
      message: 'bye'
    )
    expect(pool.autostart_plan).to have_received(:clear_ct).with(ct)
    expect(OsCtld::Commands::Container::Delete).not_to have_received(:run)
  end

  it 'deletes ephemeral containers without clearing autostart state' do
    ct = build_ct(pool:, id: 'tmp', ephemeral: true)
    stub_containers_registry([ct])

    described_class.new(pool).start
    executor.enqueued.first.send(:exec)

    expect(OsCtld::Commands::Container::Delete).to have_received(:run).with(
      pool: 'tank',
      id: 'tmp',
      force: true,
      progress: false,
      manipulation_lock: 'ignore',
      message: nil
    )
    expect(pool.autostart_plan).not_to have_received(:clear_ct)
  end

  it 'reports progress to the client handler' do
    persistent = build_ct(pool:, id: 'persist')
    ephemeral = build_ct(pool:, id: 'tmp', ephemeral: true)
    client_handler = client_handler_double
    stub_containers_registry([persistent, ephemeral])

    described_class.new(pool).start(client_handler:)
    executor.enqueued.each { |cmd| cmd.send(:exec) }

    expect(client_handler).to have_received(:send_update).with('[1/2] Stopping container tank:persist')
    expect(client_handler).to have_received(:send_update).with('[2/2] Deleting ephemeral container tank:tmp')
  end

  it 'delegates queue control helpers to the executor' do
    plan = described_class.new(pool)

    plan.clear
    plan.resize(9)
    plan.wait
    plan.stop

    expect(executor.cleared?).to be(true)
    expect(executor.resized_to).to eq(9)
    expect(executor.waited?).to be(true)
    expect(executor.stopped?).to be(true)
    expect(plan.queue).to eq([])
    expect(plan.log_type).to eq('tank:auto-stop')
  end
end
