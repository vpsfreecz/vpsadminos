# frozen_string_literal: true

require 'osctld/continuous_executor'
require 'osctld/auto_start/config'
require 'osctld/auto_start/state'
require 'osctld/auto_start/reboot'
require 'osctld/auto_start/plan'

RSpec.describe OsCtld::AutoStart::Plan do
  def stub_commands(start_return: { status: true })
    stub_const('OsCtld::Commands', Module.new)
    stub_const('OsCtld::Commands::Container', Module.new)
    stub_const('OsCtld::Commands::Container::Start', Class.new do
      def self.run(*)
        { status: true }
      end
    end)
    allow(OsCtld::Commands::Container::Start).to receive(:run).and_return(start_return)
  end

  def stub_cpu_scheduler(use: false, sequential: false, package_ids: {})
    stub_const('OsCtld::CpuScheduler', Module.new do
      def self.use?
        false
      end

      def self.use_sequential_start_stop?
        false
      end

      def self.preschedule_ct(_ct); end

      def self.get_preschedule_package_id(_ct)
        nil
      end

      def self.cancel_preschedule_ct(_ct); end
    end)

    allow(OsCtld::CpuScheduler).to receive_messages(
      use?: use,
      use_sequential_start_stop?: sequential
    )
    allow(OsCtld::CpuScheduler).to receive(:get_preschedule_package_id) do |ct|
      package_ids[ct.id]
    end
    allow(OsCtld::CpuScheduler).to receive(:preschedule_ct)
    allow(OsCtld::CpuScheduler).to receive(:cancel_preschedule_ct)
  end

  def build_ct(pool:, id:, autostart: nil, usage_us: 0, can_start: true, running: false)
    ct = FakeObjects::FakeRuntimeContainer.new(
      pool:,
      id:,
      autostart:,
      can_start:,
      running:,
      hints: Struct.new(:cpu_daily).new(Struct.new(:usage_us).new(usage_us))
    )
    request = Struct.new(:action, :run_id, :intent_id, :warning).new
    lifecycle = Class.new do
      def initialize(request)
        @request = request
      end

      def autostart_intent? = false

      def request_start(source:) = @request
    end.new(request)
    ct.lifecycle = lifecycle
    ct
  end

  let(:pool) do
    Struct.new(:name, :parallel_start, :autostart_dir).new(
      'tank',
      2,
      File.join(Dir.mktmpdir('osctld-autostart-plan'), 'autostart')
    )
  end
  let(:executor) { RuntimePolicyHelpers::RecordingExecutor.new }
  let(:state) { instance_double(OsCtld::AutoStart::State, is_started?: false, set_started: nil, clear: nil, assets: nil) }
  let(:reboot) { instance_double(OsCtld::AutoStart::Reboot, include?: false, add: nil, clear: nil, assets: nil) }

  before do
    FileUtils.mkdir_p(pool.autostart_dir)
    container_class = Class.new
    container_class.const_set(:DEFAULT_START_TIMEOUT, 120)
    stub_const('OsCtld::Container', container_class)
    OsCtl::Lib::Logger.setup(:none)
    stub_daemon(debug: false)
    stub_cpu_scheduler
    stub_commands
    allow(OsCtld::AutoStart::State).to receive(:load).and_return(state)
    allow(OsCtld::AutoStart::Reboot).to receive(:load).and_return(reboot)
    allow(OsCtld::ContinuousExecutor).to receive(:new).and_return(executor)
    allow(OsCtl::Lib::LoadAvg).to receive(:new).and_return(instance_double(OsCtl::Lib::LoadAvg, avg: [0.0, 0.0, 0.0]))
  end

  after do
    FileUtils.rm_rf(File.dirname(pool.autostart_dir))
  end

  it 'selects only startable containers from the requested pool' do
    eligible = build_ct(
      pool:,
      id: 'autostart',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 10, delay: 0, ct_id: 'autostart')
    )
    rebooted = build_ct(pool:, id: 'rebooted')
    already_started = build_ct(
      pool:,
      id: 'started',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 20, delay: 0, ct_id: 'started')
    )
    other_pool = build_ct(
      pool: Struct.new(:name, :parallel_start, :autostart_dir).new('other', 2, pool.autostart_dir),
      id: 'other',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 30, delay: 0, ct_id: 'other')
    )
    not_startable = build_ct(
      pool:,
      id: 'blocked',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 40, delay: 0, ct_id: 'blocked'),
      can_start: false
    )

    allow(reboot).to receive(:include?) { |ct| ct.id == 'rebooted' }
    allow(state).to receive(:is_started?) { |ct| ct.id == 'started' }
    stub_containers_registry([eligible, rebooted, already_started, other_pool, not_startable])

    described_class.new(pool).start

    expect(executor.enqueued.map(&:id)).to eq(%w[autostart rebooted])
  end

  it 'persists the desired lifecycle intent before queueing a boot start' do
    ct = build_ct(
      pool:,
      id: 'ct1',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(
        priority: 10,
        delay: 0,
        ct_id: 'ct1'
      )
    )
    request = Struct.new(:action, :run_id, :intent_id, :warning).new(
      :launch,
      'tank:ct1:run-1',
      'intent-1',
      nil
    )
    lifecycle_class = Class.new do
      def autostart_intent?; end

      def request_start(source:); end

      def cancel_unlaunched(*, **); end
    end
    lifecycle = instance_double(
      lifecycle_class,
      autostart_intent?: false,
      request_start: request,
      cancel_unlaunched: true
    )
    ct.lifecycle = lifecycle
    stub_containers_registry([ct])

    plan = described_class.new(pool)
    allow(plan).to receive(:interruptible_sleep)
    plan.start

    expect(lifecycle).to have_received(:request_start).with(source: 'autostart')
    expect(executor.enqueued.map(&:id)).to eq(['ct1'])

    executor.enqueued.first.send(:exec)
    expect(OsCtld::Commands::Container::Start).to have_received(:run).with(
      hash_including(
        lifecycle_source: 'autostart',
        lifecycle_intent_id: 'intent-1'
      )
    )
  end

  it 'reschedules a durable autostart intent even when autostart was disabled' do
    ct = build_ct(pool:, id: 'ct1')
    request = Struct.new(:action, :run_id, :intent_id, :warning).new(
      :launch,
      'tank:ct1:run-2',
      'intent-2',
      nil
    )
    lifecycle_class = Class.new do
      def autostart_intent?; end

      def request_start(source:); end

      def cancel_unlaunched(*, **); end
    end
    lifecycle = instance_double(
      lifecycle_class,
      autostart_intent?: true,
      request_start: request,
      cancel_unlaunched: true
    )
    ct.lifecycle = lifecycle
    stub_containers_registry([ct])

    described_class.new(pool).start

    expect(executor.enqueued.map(&:id)).to eq(['ct1'])
    expect(lifecycle).to have_received(:request_start).with(source: 'autostart')
  end

  it 'cancels queued unlaunched generations while preserving desired running on pause' do
    ct = build_ct(
      pool:,
      id: 'ct1',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(
        priority: 10,
        delay: 0,
        ct_id: 'ct1'
      )
    )
    request = Struct.new(:action, :run_id, :intent_id, :warning).new(
      :launch,
      'tank:ct1:run-1',
      'intent-1',
      nil
    )
    lifecycle_class = Class.new do
      def autostart_intent?; end

      def request_start(source:); end

      def cancel_unlaunched(*, **); end
    end
    lifecycle = instance_double(
      lifecycle_class,
      autostart_intent?: false,
      request_start: request,
      cancel_unlaunched: true
    )
    ct.lifecycle = lifecycle
    stub_containers_registry([ct])

    plan = described_class.new(pool)
    plan.start
    plan.pause

    expect(lifecycle).to have_received(:cancel_unlaunched).with(
      'tank:ct1:run-1',
      'autostart paused before launch',
      preserve_desired: true,
      source: 'autostart-cancel'
    )
    expect(executor.cleared?).to be(true)
  end

  it 'preschedules only stopped containers in descending daily CPU use order' do
    first = build_ct(
      pool:,
      id: 'first',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 20, delay: 0, ct_id: 'first'),
      usage_us: 20
    )
    second = build_ct(
      pool:,
      id: 'second',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 10, delay: 0, ct_id: 'second'),
      usage_us: 50
    )
    running = build_ct(
      pool:,
      id: 'running',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 30, delay: 0, ct_id: 'running'),
      usage_us: 100,
      running: true
    )

    stub_cpu_scheduler(use: true)
    stub_containers_registry([first, second, running])

    described_class.new(pool).start

    expect(OsCtld::CpuScheduler).to have_received(:preschedule_ct).with(second).ordered
    expect(OsCtld::CpuScheduler).to have_received(:preschedule_ct).with(first).ordered
    expect(OsCtld::CpuScheduler).not_to have_received(:preschedule_ct).with(running)
  end

  it 'orders sequential starts by package before autostart priority' do
    pkg1 = build_ct(
      pool:,
      id: 'pkg1',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 30, delay: 0, ct_id: 'pkg1')
    )
    pkg0_high = build_ct(
      pool:,
      id: 'pkg0-high',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 20, delay: 0, ct_id: 'pkg0-high')
    )
    pkg0_low = build_ct(
      pool:,
      id: 'pkg0-low',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 5, delay: 0, ct_id: 'pkg0-low')
    )
    unassigned = build_ct(
      pool:,
      id: 'unassigned',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 1, delay: 0, ct_id: 'unassigned')
    )

    stub_cpu_scheduler(
      use: true,
      sequential: true,
      package_ids: {
        'pkg1' => 1,
        'pkg0-high' => 0,
        'pkg0-low' => 0,
        'unassigned' => nil
      }
    )
    stub_containers_registry([pkg1, pkg0_high, pkg0_low, unassigned])

    described_class.new(pool).start

    expect(executor.enqueued.map(&:id)).to eq(%w[pkg0-low pkg0-high pkg1 unassigned])
  end

  it 'starts reboot-requested containers without autostart config' do
    ct = build_ct(pool:, id: 'ct1', autostart: nil)

    allow(reboot).to receive(:include?).and_return(true)
    stub_containers_registry([ct])

    plan = described_class.new(pool)
    allow(plan).to receive(:interruptible_sleep)
    allow(plan).to receive(:rand).and_return(0.0)

    plan.start

    expect { executor.enqueued.first.send(:exec) }.not_to raise_error
    expect(OsCtld::Commands::Container::Start).to have_received(:run).with(
      hash_including(pool: 'tank', id: 'ct1', wait: 'infinity')
    )
  end

  it 'marks containers as started on the first successful start attempt' do
    ct = build_ct(
      pool:,
      id: 'ct1',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 10, delay: 5, ct_id: 'ct1')
    )
    plan = described_class.new(pool)

    allow(plan).to receive(:delay_after_start?).and_return(false)
    allow(plan).to receive(:log)

    plan.send(:do_try_start_ct, ct)

    expect(state).to have_received(:set_started).with(ct)
    expect(OsCtld::Commands::Container::Start).to have_received(:run).once
  end

  it 'retries failed starts with increasing cooldowns' do
    ct = build_ct(
      pool:,
      id: 'ct1',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 10, delay: 0, ct_id: 'ct1')
    )
    plan = described_class.new(pool)

    allow(plan).to receive(:delay_after_start?).and_return(false)
    allow(plan).to receive(:log)
    allow(plan).to receive(:interruptible_sleep)
    allow(OsCtld::Commands::Container::Start).to receive(:run).and_return(
      { status: false },
      { status: true }
    )

    plan.send(:do_try_start_ct, ct, attempts: 2, cooldown: 5)

    expect(plan).to have_received(:interruptible_sleep).with(5)
    expect(state).to have_received(:set_started).with(ct)
  end

  it 'logs and stops after exhausting all start attempts' do
    ct = build_ct(
      pool:,
      id: 'ct1',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 10, delay: 0, ct_id: 'ct1')
    )
    plan = described_class.new(pool)

    allow(plan).to receive(:interruptible_sleep)
    allow(plan).to receive(:log)
    allow(OsCtld::Commands::Container::Start).to receive(:run).and_return({ status: false })

    plan.send(:do_try_start_ct, ct, attempts: 3, cooldown: 5)

    expect(plan).to have_received(:log).with(:warn, ct, 'All attempts to start the container have failed')
  end

  it 'stops retrying when the plan is asked to stop' do
    ct = build_ct(
      pool:,
      id: 'ct1',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 10, delay: 0, ct_id: 'ct1')
    )
    plan = described_class.new(pool)

    allow(plan).to receive(:interruptible_sleep)
    allow(plan).to receive(:log)
    allow(plan).to receive(:stop?).and_return(false, true)
    allow(OsCtld::Commands::Container::Start).to receive(:run).and_return({ status: false })

    plan.send(:do_try_start_ct, ct, attempts: 3, cooldown: 5)

    expect(OsCtld::Commands::Container::Start).to have_received(:run).once
    expect(plan).to have_received(:log).with(:warn, ct, 'Unable to start the container, giving up to stop')
  end

  it 'enqueues starts with queue disabled and executes immediate starts with the requested timeout' do
    ct = build_ct(
      pool:,
      id: 'ct1',
      autostart: RuntimePolicyHelpers::FakeAutostart.new(priority: 10, delay: 0, ct_id: 'ct1')
    )
    stub_containers_registry([ct])

    plan = described_class.new(pool)
    allow(plan).to receive(:interruptible_sleep)
    allow(plan).to receive(:rand).and_return(0.0)

    plan.enqueue(ct, start_opts: { wait: 33, foo: :bar })
    executor.enqueued.first.send(:exec)
    expect(OsCtld::Commands::Container::Start).to have_received(:run).with(
      hash_including(pool: 'tank', id: 'ct1', queue: false, wait: 'infinity', foo: :bar)
    )

    allow(OsCtld::Commands::Container::Start).to receive(:run).and_return(status: true)
    plan.start_ct(ct, start_opts: { wait: 44 })

    expect(executor.last_timeout).to eq(44)
    expect(OsCtld::Commands::Container::Start).to have_received(:run).with(
      hash_including(pool: 'tank', id: 'ct1', queue: false)
    ).at_least(:once)
  end

  it 'delegates state, reboot, and executor helpers' do
    ct = build_ct(pool:, id: 'ct1')
    stub_containers_registry([ct])
    plan = described_class.new(pool)

    plan.fulfil_start(ct)
    plan.request_reboot(ct)
    plan.fulfil_reboot(ct)
    plan.stop_ct(ct)
    plan.clear_ct(ct)
    plan.clear
    plan.resize(8)
    plan.stop

    expect(state).to have_received(:set_started).with(ct)
    expect(reboot).to have_received(:add).with(ct)
    expect(reboot).to have_received(:clear).with(ct).twice
    expect(state).to have_received(:clear).with(ct)
    expect(executor.removed_ids).to eq(['ct1'])
    expect(executor.cleared?).to be(true)
    expect(executor.resized_to).to eq(8)
    expect(executor.stopped?).to be(true)
    expect(plan.started?).to be(false)
    expect(plan.queue).to eq([])
    expect(plan.log_type).to eq('tank:auto-start')
  end
end
