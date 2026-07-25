# frozen_string_literal: true

require 'osctld/cpu_scheduler'

RSpec.describe OsCtld::CpuScheduler do
  def build_topology(*package_cpu_sets)
    packages = package_cpu_sets.to_h do |pkg_id, cpus|
      [
        pkg_id,
        RuntimePolicyHelpers::FakeTopologyPackage.new(
          id: pkg_id,
          cpus: cpus.to_h { |cpu| [cpu, true] }
        )
      ]
    end

    RuntimePolicyHelpers::FakeTopology.new(packages:, cpus: package_cpu_sets.flat_map(&:last))
  end

  def build_ct(pool:, id:, usage_us: 0, cpu_package: 'auto', autostart_priority: nil)
    cgparams_class = Class.new do
      def set(_params); end
    end

    FakeObjects::FakeRuntimeContainer.new(
      pool:,
      id:,
      cpu_package:,
      autostart: autostart_priority && RuntimePolicyHelpers::FakeAutostart.new(
        priority: autostart_priority,
        delay: 0,
        ct_id: id
      ),
      hints: Struct.new(:cpu_daily).new(Struct.new(:usage_us).new(usage_us)),
      cgparams: instance_double(cgparams_class, set: nil)
    )
  end

  def build_run_configuration(ct)
    Struct.new(:ct, :cpu_package, :save_calls) do
      def initialize(run_ct)
        super(run_ct, nil, 0)
      end

      def ident
        ct.ident
      end

      def pool
        ct.pool
      end

      def id
        ct.id
      end

      def cgroup_root
        File.join(ct.base_cgroup_path, 'runs', 'run-1')
      end

      def save
        self.save_calls += 1
      end
    end.new(ct)
  end

  let(:pool) { Struct.new(:name).new('tank') }
  let(:topology) { build_topology([0, [0, 1]], [1, [2, 3]]) }
  let(:scheduler_cfg) do
    DaemonHelpers::SchedulerConfig.new(
      enable_flag: true,
      min_package_container_count_percent: 75,
      packages: {
        0 => DaemonHelpers::SchedulerPackageConfig.new(
          cpu_mask: RuntimePolicyHelpers::FakeCpuMask.new([0]),
          enable: false
        )
      },
      sequential_start_priority_threshold: 50
    )
  end

  before do
    OsCtl::Lib::Logger.setup(:none)
    stub_daemon(cpu_scheduler: scheduler_cfg)
    stub_const('OsCtld::Eventd', Module.new do
      def self.report(*); end
    end)
    stub_const('OsCtld::CGroup', Module.new do
      def self.mkpath(*); end

      def self.set_param(*)
        true
      end

      def self.abs_cgroup_path(subsystem, path)
        File.join('/sys/fs/cgroup', subsystem, path)
      end
    end)
    stub_const('OsCtld::CGroup::Param', Class.new do
      def self.import(hash)
        hash
      end
    end)
    allow(OsCtl::Lib::CpuTopology).to receive(:new).and_return(topology)
    allow(OsCtl::Lib::CpuMask).to receive(:new) do |cpus|
      RuntimePolicyHelpers::FakeCpuMask.new(cpus)
    end
  end

  it 'builds package state from topology and daemon config' do
    scheduler = fresh_singleton(described_class)

    expect(scheduler.export_packages).to eq(
      [
        { id: 0, cpus: [0], containers: 0, usage_score: 0, enabled: false },
        { id: 1, cpus: [2, 3], containers: 0, usage_score: 0, enabled: true }
      ]
    )
  end

  it 'reports whether the scheduler is enabled, needed, and usable' do
    scheduler = fresh_singleton(described_class)

    expect(scheduler.enabled?).to be(true)
    expect(scheduler.needed?).to be(true)
    expect(scheduler.use?).to be(true)
    expect(scheduler.use_sequential_start_stop?).to be(true)

    allow(OsCtl::Lib::CpuTopology).to receive(:new).and_return(build_topology([0, [0, 1]]))
    single_package = fresh_singleton(described_class)

    expect(single_package.needed?).to be(false)
    expect(single_package.use?).to be(false)
    expect(single_package.use_sequential_start_stop?).to be(false)
  end

  it 'toggles packages and rejects unknown package ids' do
    scheduler = fresh_singleton(described_class)

    expect(scheduler.enable_package(0)).to be(true)
    expect(scheduler.disable_package(1)).to be(true)
    expect(scheduler.disable_package(9)).to be(false)

    expect(scheduler.export_packages).to include(
      include(id: 0, enabled: true),
      include(id: 1, enabled: false)
    )
  end

  it 'schedules by container count before score scheduling is available' do
    scheduler = fresh_singleton(described_class)
    first = build_ct(pool:, id: 'ct1', usage_us: 0)
    second = build_ct(pool:, id: 'ct2', usage_us: 0)

    first_pkg, = scheduler.send(:assign_package_for, first)
    second_pkg, = scheduler.send(:assign_package_for, second)

    expect(first_pkg.id).to eq(1)
    expect(second_pkg.id).to eq(1)
    expect(scheduler.export_packages).to include(include(id: 1, containers: 2, usage_score: 0))
  end

  it 'schedules by usage score once package counts are balanced' do
    scheduler = fresh_singleton(described_class)
    ct0 = build_ct(pool:, id: 'ct0', usage_us: 10)
    ct1 = build_ct(pool:, id: 'ct1', usage_us: 10)
    ct2 = build_ct(pool:, id: 'ct2', usage_us: 5)

    scheduler.enable_package(0)
    scheduler.send(:assign_package_for, ct0)
    scheduler.send(:assign_package_for, ct1)
    scheduler.send(:assign_package_for, ct2)

    packages = scheduler.export_packages
    expect(packages.find { |pkg| pkg[:id] == 0 }[:usage_score]).to eq(10)
    expect(packages.find { |pkg| pkg[:id] == 1 }[:usage_score]).to eq(15)
  end

  it 'does not select disabled packages for priority starts' do
    scheduler = fresh_singleton(described_class)
    ct = build_ct(pool:, id: 'ct1', usage_us: 10, autostart_priority: 10)

    pkg, = scheduler.send(:assign_package_for, ct)

    expect(pkg.id).to eq(1)
  end

  it 'tracks and cancels prescheduled reservations' do
    scheduler = fresh_singleton(described_class)
    scheduler.enable_package(0)
    ct = build_ct(pool:, id: 'ct1', usage_us: 10)

    scheduler.preschedule_ct(ct)

    expect(scheduler.get_preschedule_package_id(ct)).not_to be_nil
    expect(scheduler.export_packages.sum { |pkg| pkg[:containers] }).to eq(1)

    scheduler.cancel_preschedule_ct(ct)

    expect(scheduler.get_preschedule_package_id(ct)).to be_nil
    expect(scheduler.export_packages.sum { |pkg| pkg[:containers] }).to eq(0)
  end

  it 'stages cpuset configuration and unschedules containers' do
    scheduler = fresh_singleton(described_class)
    scheduler.enable_package(0)
    ct = build_ct(pool:, id: 'ct1', usage_us: 10)
    ctrc = build_run_configuration(ct)

    allow(OsCtld::CGroup).to receive(:mkpath)
    allow(OsCtld::CGroup).to receive(:set_param).and_return(true)
    allow(OsCtld::Eventd).to receive(:report)

    scheduler.schedule_ct(ctrc)

    expect(OsCtld::CGroup).to have_received(:mkpath).with(
      'cpuset',
      ['', 'osctl', 'pool.tank', 'ct.ct1', 'runs', 'run-1'],
      leaf: false
    )
    expect(OsCtld::CGroup).not_to have_received(:set_param)
    expect(ct.cgparams).to have_received(:set).with(
      [hash_including(subsystem: 'cpuset', parameter: 'cpuset.cpus', persistent: false)]
    )
    expect(ctrc.cpu_package).not_to be_nil
    expect(scheduler.package_mask(ctrc.cpu_package)).to match(/\A[0-9,]+\z/)
    expect(ctrc.save_calls).to eq(1)

    scheduler.unschedule_ct(ct)

    expect(scheduler.get_preschedule_package_id(ct)).to be_nil
  end

  it 'reuses a quarantined generation assignment without double-counting it' do
    scheduler = fresh_singleton(described_class)
    scheduler.enable_package(0)
    ct = build_ct(pool:, id: 'ct1', usage_us: 10)
    first = build_run_configuration(ct)
    replacement = build_run_configuration(ct)

    scheduler.schedule_ct(first)
    before = scheduler.export_packages
    scheduler.schedule_ct(replacement)

    expect(replacement.cpu_package).to eq(first.cpu_package)
    expect(scheduler.export_packages).to eq(before)
  end

  it 'exports and reloads persisted scheduler state' do
    with_tmpdir do |dir|
      scheduler = fresh_singleton(described_class)
      scheduler.enable_package(0)
      scheduler.disable

      state_file = File.join(dir, 'state.yml')
      stub_const("#{described_class}::STATE_FILE", state_file)
      data = scheduler.send(:dump_state).merge(
        'packages' => [{ 'id' => 0, 'enabled' => true }, { 'id' => 1, 'enabled' => false }],
        'scheduled_cts' => [
          {
            'ctid' => 'tank:ct1',
            'usage_score' => 50,
            'package_id' => 0,
            'reservation' => true,
            'reserved_at' => Time.now.to_i
          }
        ]
      )
      write_yaml_file(state_file, data)

      reloaded = fresh_singleton(described_class)
      reloaded.send(:load_state)

      expect(reloaded.export_status).to include(enabled: false, needed: true, use: false)
      expect(reloaded.export_packages).to include(
        include(id: 0, enabled: true, containers: 1, usage_score: 50),
        include(id: 1, enabled: false)
      )
    end
  end
end
