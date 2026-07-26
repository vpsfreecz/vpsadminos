# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'osctld/cgroup/cpu_bandwidth_policy'
require 'osctld/cgroup/param'

RSpec.describe OsCtld::CGroup::CpuBandwidthPolicy do
  attr_reader :tmpdir, :root, :active_root, :active_payload,
              :residual_root, :residual_host_effects, :residual_payload,
              :runs, :lifecycle, :owner, :writes, :rejections,
              :disappearances

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
    @residual_host_effects = File.join(residual_root, 'host-effects')
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
    @disappearances = []

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
      disappeared = disappearances.delete([cgroup, parameter, value])
      if disappeared
        FileUtils.rm_rf(cgroup)
        next false
      end
      next false if rejected || !valid_write?(cgroup, proposed)

      File.write(path, value.to_s)
      true
    end
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  it 'moves an active payload limit to the stable parent' do
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
        [active_payload, described_class::QUOTA_PARAMETER, -1],
        [root, described_class::QUOTA_PARAMETER, 250_000]
      ]
    )
    expect(state(root)).to eq([250_000, 100_000])
    expect(state(active_payload)).to eq([-1, 100_000])
  end

  it 'releases the active payload before expanding the stable parent' do
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
        [active_payload, described_class::QUOTA_PARAMETER, -1],
        [root, described_class::QUOTA_PARAMETER, 400_000]
      ]
    )
    expect(state(root)).to eq([400_000, 100_000])
    expect(state(active_payload)).to eq([-1, 100_000])
  end

  it 'does not change an ancestor when the payload disappears on release' do
    File.write(
      File.join(root, described_class::QUOTA_PARAMETER),
      '250000'
    )
    File.write(
      File.join(active_payload, described_class::QUOTA_PARAMETER),
      '250000'
    )
    disappearances << [
      active_payload,
      described_class::QUOTA_PARAMETER,
      -1
    ]
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 100_000),
        param(described_class::QUOTA_PARAMETER, 400_000)
      ],
      root:
    )

    expect { policy.apply }.to raise_error(
      described_class::Error,
      /kernel rejected cpu\.cfs_quota_us=-1/
    )

    expect(writes).to eq(
      [[active_payload, described_class::QUOTA_PARAMETER, -1]]
    )
    expect(state(root)).to eq([250_000, 100_000])
    expect(File).not_to exist(active_payload)
  end

  it 'rejects an impossible live quota and period transition without writes' do
    originals = {
      root => state(root),
      active_payload => state(active_payload)
    }
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 200_000),
        param(described_class::QUOTA_PARAMETER, 500_000)
      ],
      root:
    )

    expect { policy.apply }.to raise_error(
      described_class::Error,
      /cannot transition CPU bandwidth monotonically.*while live/
    )

    expect(writes).to be_empty
    originals.each do |path, original|
      expect(state(path)).to eq(original)
    end
  end

  it 'rejects a live finite rescale with equal bandwidth without writes' do
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 200_000),
        param(described_class::QUOTA_PARAMETER, 800_000)
      ],
      root:
    )

    expect { policy.apply }.to raise_error(
      described_class::Error,
      /cannot transition CPU bandwidth monotonically.*while live/
    )
    expect(writes).to be_empty
    expect(state(root)).to eq([400_000, 100_000])
    expect(state(active_payload)).to eq([400_000, 100_000])
  end

  it 'applies a safe paired restriction from leaves to root' do
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 200_000),
        param(described_class::QUOTA_PARAMETER, 250_000)
      ],
      root:
    )

    policy.apply

    expect(writes).to eq(
      [
        [active_payload, described_class::QUOTA_PARAMETER, -1],
        [root, described_class::QUOTA_PARAMETER, 250_000],
        [root, described_class::PERIOD_PARAMETER, 200_000]
      ]
    )
    expect(state(root)).to eq([250_000, 200_000])
    expect(state(active_payload)).to eq([-1, 100_000])
  end

  it 'applies a safe paired expansion from root to leaves' do
    File.write(
      File.join(root, described_class::QUOTA_PARAMETER),
      '250000'
    )
    File.write(
      File.join(root, described_class::PERIOD_PARAMETER),
      '200000'
    )
    File.write(
      File.join(active_payload, described_class::QUOTA_PARAMETER),
      '250000'
    )
    File.write(
      File.join(active_payload, described_class::PERIOD_PARAMETER),
      '200000'
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
        [active_payload, described_class::QUOTA_PARAMETER, -1],
        [root, described_class::QUOTA_PARAMETER, 400_000],
        [root, described_class::PERIOD_PARAMETER, 100_000]
      ]
    )
    expect(state(root)).to eq([400_000, 100_000])
    expect(state(active_payload)).to eq([-1, 200_000])
  end

  it 'does not broaden a residual generation' do
    create_cgroup(residual_root, quota: -1, period: 100_000)
    create_cgroup(
      residual_host_effects,
      quota: 250_000,
      period: 100_000
    )
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
    expect(state(active_payload)).to eq([-1, 100_000])
    expect(state(residual_root)).to eq([250_000, 100_000])
    expect(state(residual_host_effects)).to eq([-1, 100_000])
    expect(state(residual_payload)).to eq([-1, 100_000])

    stable_expansion = writes.index(
      [root, described_class::QUOTA_PARAMETER, 400_000]
    )
    expect(stable_expansion).not_to be_nil
    expect(
      writes.index(
        [residual_root, described_class::QUOTA_PARAMETER, 250_000]
      )
    ).to be < stable_expansion
    released = [
      [active_payload, described_class::QUOTA_PARAMETER, -1],
      [residual_host_effects, described_class::QUOTA_PARAMETER, -1],
      [residual_payload, described_class::QUOTA_PARAMETER, -1]
    ]
    expect(writes).to include(*released)
    released.each do |write|
      expect(writes.index(write)).to be < stable_expansion
    end
  end

  it 'preflights an impossible transition before pinning residuals' do
    create_cgroup(residual_root, quota: -1, period: 100_000)
    create_cgroup(
      residual_host_effects,
      quota: 500_000,
      period: 100_000
    )
    create_cgroup(
      File.join(residual_root, 'user-owned'),
      quota: -1,
      period: 100_000
    )
    create_cgroup(residual_payload, quota: -1, period: 100_000)
    runs['residual'] = lifecycle_run(
      :residual,
      'ct.test/runs/residual',
      'ct.test/runs/residual/user-owned/payload'
    )
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 200_000),
        param(described_class::QUOTA_PARAMETER, 500_000)
      ],
      root:
    )

    expect { policy.apply }.to raise_error(
      described_class::Error,
      /cannot transition CPU bandwidth monotonically.*while live/
    )

    expect(writes).to be_empty
    expect(state(root)).to eq([400_000, 100_000])
    expect(state(active_payload)).to eq([400_000, 100_000])
    expect(state(residual_root)).to eq([-1, 100_000])
    expect(state(residual_host_effects)).to eq([500_000, 100_000])
    expect(state(residual_payload)).to eq([-1, 100_000])
  end

  it 'rolls back broad residual requests behind their original ancestor cap' do
    create_cgroup(residual_root, quota: -1, period: 100_000)
    create_cgroup(
      residual_host_effects,
      quota: -1,
      period: 100_000
    )
    create_cgroup(
      File.join(residual_root, 'user-owned'),
      quota: -1,
      period: 100_000
    )
    create_cgroup(residual_payload, quota: -1, period: 100_000)
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
    rejections << [active_payload, described_class::QUOTA_PARAMETER, -1]
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 100_000),
        param(described_class::QUOTA_PARAMETER, 400_000)
      ],
      root:
    )

    expect { policy.apply }.to raise_error(
      described_class::Error,
      /kernel rejected cpu.cfs_quota_us=-1/
    )

    expect(state(root)).to eq([250_000, 100_000])
    expect(state(active_payload)).to eq([250_000, 100_000])
    expect(state(residual_root)).to eq([-1, 100_000])
    expect(state(residual_host_effects)).to eq([-1, 100_000])
    expect(state(residual_payload)).to eq([-1, 100_000])
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

  it 'allows an unlimited local request below a finite external parent' do
    create_cgroup(tmpdir, quota: 150_000, period: 100_000)
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 100_000),
        param(described_class::QUOTA_PARAMETER, -1)
      ],
      root:
    )

    result = policy.apply

    expect(result.target).to eq(
      'quota_us' => -1,
      'period_us' => 100_000
    )
    expect(state(root)).to eq([-1, 100_000])
    expect(state(active_payload)).to eq([-1, 100_000])
    expect(state(tmpdir)).to eq([150_000, 100_000])
  end

  it 'rejects a negative v1 quota other than the unlimited value' do
    policy = described_class.new(
      owner,
      [
        param(described_class::PERIOD_PARAMETER, 100_000),
        param(described_class::QUOTA_PARAMETER, -2)
      ],
      root:
    )

    expect { policy.apply }.to raise_error(
      described_class::Error,
      /invalid cpu\.cfs_quota_us value -2/
    )
    expect(writes).to be_empty
  end

  context 'with cgroup v2' do
    def v2_param(value)
      OsCtld::CGroup::Param.new(
        2,
        'cpu',
        described_class::V2_PARAMETER,
        [value],
        true
      )
    end

    def create_v2_cgroup(path, quota:, period:)
      FileUtils.mkdir_p(path)
      value = "#{quota < 0 ? 'max' : quota} #{period}"
      File.write(File.join(path, described_class::V2_PARAMETER), value)
    end

    def v2_state(path)
      quota, period =
        File.read(File.join(path, described_class::V2_PARAMETER)).split
      [quota == 'max' ? -1 : quota.to_i, period.to_i]
    end

    before do
      allow(OsCtld::CGroup).to receive_messages(
        version: 2,
        v1?: false,
        v2?: true
      )

      FileUtils.rm_rf(root)
      create_v2_cgroup(root, quota: 250_000, period: 100_000)
      create_v2_cgroup(active_root, quota: -1, period: 100_000)
      create_v2_cgroup(
        File.join(active_root, 'user-owned'),
        quota: -1,
        period: 100_000
      )
      create_v2_cgroup(active_payload, quota: 250_000, period: 100_000)

      allow(OsCtld::CGroup).to receive(:set_param) do |path, values|
        value = values.last.to_s
        cgroup = File.dirname(path)
        parameter = File.basename(path)
        writes << [cgroup, parameter, value]

        rejected = rejections.delete([cgroup, parameter, value])
        next false if rejected

        File.write(path, value)
        true
      end
    end

    it 'pins unlimited and wider residual requests before expanding cpu.max' do
      create_v2_cgroup(residual_root, quota: -1, period: 100_000)
      create_v2_cgroup(
        residual_host_effects,
        quota: 500_000,
        period: 100_000
      )
      create_v2_cgroup(
        File.join(residual_root, 'user-owned'),
        quota: -1,
        period: 100_000
      )
      create_v2_cgroup(residual_payload, quota: 500_000, period: 100_000)
      runs['residual'] = lifecycle_run(
        :residual,
        'ct.test/runs/residual',
        'ct.test/runs/residual/user-owned/payload'
      )
      policy = described_class.new(
        owner,
        [v2_param('400000 100000')],
        root:
      )

      policy.apply

      expect(v2_state(root)).to eq([400_000, 100_000])
      expect(v2_state(active_payload)).to eq([-1, 100_000])
      expect(v2_state(residual_root)).to eq([250_000, 100_000])
      expect(v2_state(residual_host_effects)).to eq([-1, 100_000])
      expect(v2_state(residual_payload)).to eq([-1, 100_000])

      stable_expansion = writes.index(
        [root, described_class::V2_PARAMETER, '400000 100000']
      )
      expect(stable_expansion).not_to be_nil
      expect(
        writes.index(
          [
            residual_root,
            described_class::V2_PARAMETER,
            '250000 100000'
          ]
        )
      ).to be < stable_expansion
      released = [
        [
          active_payload,
          described_class::V2_PARAMETER,
          'max 100000'
        ],
        [
          residual_host_effects,
          described_class::V2_PARAMETER,
          'max 100000'
        ],
        [
          residual_payload,
          described_class::V2_PARAMETER,
          'max 100000'
        ]
      ]
      expect(writes).to include(*released)
      released.each do |write|
        expect(writes.index(write)).to be < stable_expansion
      end
    end

    it 'rolls back cpu.max without broadening residual requests' do
      create_v2_cgroup(residual_root, quota: -1, period: 100_000)
      create_v2_cgroup(
        residual_host_effects,
        quota: 500_000,
        period: 100_000
      )
      create_v2_cgroup(
        File.join(residual_root, 'user-owned'),
        quota: -1,
        period: 100_000
      )
      create_v2_cgroup(residual_payload, quota: -1, period: 100_000)
      runs['residual'] = lifecycle_run(
        :residual,
        'ct.test/runs/residual',
        'ct.test/runs/residual/user-owned/payload'
      )
      rejections << [
        active_payload,
        described_class::V2_PARAMETER,
        'max 100000'
      ]
      policy = described_class.new(
        owner,
        [v2_param('400000 100000')],
        root:
      )

      expect { policy.apply }.to raise_error(
        described_class::Error,
        /kernel rejected cpu.max=max 100000/
      )

      expect(v2_state(root)).to eq([250_000, 100_000])
      expect(v2_state(active_payload)).to eq([250_000, 100_000])
      expect(v2_state(residual_root)).to eq([-1, 100_000])
      expect(v2_state(residual_host_effects)).to eq([500_000, 100_000])
      expect(v2_state(residual_payload)).to eq([-1, 100_000])
    end

    it 'preserves the current period when cpu.max is reset to max' do
      File.write(
        File.join(root, described_class::V2_PARAMETER),
        '250000 200000'
      )
      File.write(
        File.join(active_payload, described_class::V2_PARAMETER),
        '250000 200000'
      )
      policy = described_class.new(owner, [v2_param('max')], root:)

      result = policy.apply

      expect(result.target).to eq(
        'quota_us' => -1,
        'period_us' => 200_000
      )
      expect(v2_state(root)).to eq([-1, 200_000])
      expect(v2_state(active_payload)).to eq([-1, 200_000])
    end

    it 'allows max below a finite external parent' do
      create_v2_cgroup(tmpdir, quota: 150_000, period: 100_000)
      policy = described_class.new(owner, [v2_param('max 100000')], root:)

      result = policy.apply

      expect(result.target).to eq(
        'quota_us' => -1,
        'period_us' => 100_000
      )
      expect(v2_state(root)).to eq([-1, 100_000])
      expect(v2_state(active_payload)).to eq([-1, 100_000])
      expect(v2_state(tmpdir)).to eq([150_000, 100_000])
    end

    it 'rejects a negative numeric cpu.max quota' do
      policy = described_class.new(
        owner,
        [v2_param('-2 100000')],
        root:
      )

      expect { policy.apply }.to raise_error(
        described_class::Error,
        /invalid cpu\.max value "-2 100000"/
      )
      expect(writes).to be_empty
    end
  end
end
