# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'osctld/cgroup/cpu_bandwidth_policy'
require 'osctld/cgroup/param'

RSpec.describe OsCtld::CGroup::CpuBandwidthPolicy do
  attr_reader :tmpdir, :root, :active_root, :active_payload,
              :residual_root, :residual_payload, :runs, :lifecycle,
              :owner, :writes, :rejections

  def param(name, value)
    OsCtld::CGroup::Param.new(1, 'cpu', name, [value], true)
  end

  def state(path)
    [
      File.read(File.join(path, described_class::QUOTA_PARAMETER)).to_i,
      File.read(File.join(path, described_class::PERIOD_PARAMETER)).to_i
    ]
  end

  def create_cgroup(path, quota:, period:)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, described_class::QUOTA_PARAMETER), quota.to_s)
    File.write(File.join(path, described_class::PERIOD_PARAMETER), period.to_s)
  end

  def bandwidth(value)
    quota, period = value
    quota < 0 ? nil : Rational(quota, period)
  end

  def valid_write?(path, proposed)
    proposed_bandwidth = bandwidth(proposed)
    return true unless proposed_bandwidth

    parent = File.dirname(path)
    until parent == File.dirname(root)
      quota_file = File.join(parent, described_class::QUOTA_PARAMETER)
      if File.exist?(quota_file)
        parent_bandwidth = bandwidth(state(parent))
        return false if parent_bandwidth && proposed_bandwidth > parent_bandwidth
      end
      break if parent == root

      parent = File.dirname(parent)
    end

    Dir.glob(
      File.join(path, '**', described_class::QUOTA_PARAMETER)
    ).all? do |child_quota_file|
      child = File.dirname(child_quota_file)
      next true if child == path

      child_bandwidth = bandwidth(state(child))
      child_bandwidth.nil? || child_bandwidth <= proposed_bandwidth
    end
  end

  def lifecycle_run(role, run_root, payload)
    {
      'role' => role.to_s,
      'resources' => {
        'cgroup_root' => run_root,
        'lxc_payload' => payload
      }
    }
  end

  before do
    @tmpdir = Dir.mktmpdir('osctld-cpu-bandwidth-')
    @root = File.join(tmpdir, 'ct.test')
    @active_root = File.join(root, 'runs', 'active')
    @active_payload = File.join(active_root, 'user-owned', 'payload')
    @residual_root = File.join(root, 'runs', 'residual')
    @residual_payload = File.join(
      residual_root,
      'user-owned',
      'payload'
    )
    @runs = {
      'active' => lifecycle_run(
        :active,
        'ct.test/runs/active',
        'ct.test/runs/active/user-owned/payload'
      )
    }
    @lifecycle = Struct.new(:runs).new(runs)
    @owner = Struct.new(:lifecycle).new(lifecycle)
    @writes = []
    @rejections = []

    create_cgroup(root, quota: 400_000, period: 100_000)
    create_cgroup(active_root, quota: -1, period: 100_000)
    create_cgroup(
      File.join(active_root, 'user-owned'),
      quota: -1,
      period: 100_000
    )
    create_cgroup(active_payload, quota: 400_000, period: 100_000)

    base = tmpdir
    allow(OsCtld::CGroup).to receive(:abs_cgroup_path) do |_subsystem, path|
      File.join(base, path)
    end
    allow(OsCtld::CGroup).to receive(:set_param) do |path, values|
      value = values.last.to_i
      cgroup = File.dirname(path)
      parameter = File.basename(path)
      current = state(cgroup)
      proposed =
        if parameter == described_class::QUOTA_PARAMETER
          [value, current.last]
        else
          [current.first, value]
        end
      writes << [cgroup, parameter, value]

      rejected = rejections.delete([cgroup, parameter, value])
      next false if rejected || !valid_write?(cgroup, proposed)

      File.write(path, value.to_s)
      true
    end
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  it 'restricts payloads before the stable parent' do
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 100_000),
        param(described_class::QUOTA_PARAMETER, 250_000)
      ],
      root:
    )

    policy.apply

    expect(writes).to eq(
      [
        [active_payload, described_class::QUOTA_PARAMETER, 250_000],
        [root, described_class::QUOTA_PARAMETER, 250_000]
      ]
    )
    expect(state(root)).to eq([250_000, 100_000])
    expect(state(active_payload)).to eq([250_000, 100_000])
  end

  it 'expands the stable parent before active payloads' do
    File.write(
      File.join(root, described_class::QUOTA_PARAMETER),
      '250000'
    )
    File.write(
      File.join(active_payload, described_class::QUOTA_PARAMETER),
      '250000'
    )
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 100_000),
        param(described_class::QUOTA_PARAMETER, 400_000)
      ],
      root:
    )

    policy.apply

    expect(writes).to eq(
      [
        [root, described_class::QUOTA_PARAMETER, 400_000],
        [active_payload, described_class::QUOTA_PARAMETER, 400_000]
      ]
    )
  end

  it 'orders quota and period without a transient parent violation' do
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 200_000),
        param(described_class::QUOTA_PARAMETER, 500_000)
      ],
      root:
    )

    policy.apply

    expect(writes).to eq(
      [
        [active_payload, described_class::PERIOD_PARAMETER, 200_000],
        [active_payload, described_class::QUOTA_PARAMETER, 500_000],
        [root, described_class::QUOTA_PARAMETER, 500_000],
        [root, described_class::PERIOD_PARAMETER, 200_000]
      ]
    )
  end

  it 'does not broaden a residual generation' do
    create_cgroup(residual_root, quota: -1, period: 100_000)
    create_cgroup(
      File.join(residual_root, 'user-owned'),
      quota: -1,
      period: 100_000
    )
    create_cgroup(residual_payload, quota: 250_000, period: 100_000)
    runs['residual'] = lifecycle_run(
      :residual,
      'ct.test/runs/residual',
      'ct.test/runs/residual/user-owned/payload'
    )
    File.write(
      File.join(root, described_class::QUOTA_PARAMETER),
      '250000'
    )
    File.write(
      File.join(active_payload, described_class::QUOTA_PARAMETER),
      '250000'
    )
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 100_000),
        param(described_class::QUOTA_PARAMETER, 400_000)
      ],
      root:
    )

    policy.apply

    expect(state(root)).to eq([400_000, 100_000])
    expect(state(active_payload)).to eq([400_000, 100_000])
    expect(state(residual_payload)).to eq([250_000, 100_000])
  end

  it 'rolls back an exact hierarchy after a rejected parent write' do
    rejections << [root, described_class::QUOTA_PARAMETER, 250_000]
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 100_000),
        param(described_class::QUOTA_PARAMETER, 250_000)
      ],
      root:
    )

    expect { policy.apply }.to raise_error(
      described_class::Error,
      /kernel rejected cpu.cfs_quota_us=250000/
    )

    expect(state(root)).to eq([400_000, 100_000])
    expect(state(active_payload)).to eq([400_000, 100_000])
  end
end
