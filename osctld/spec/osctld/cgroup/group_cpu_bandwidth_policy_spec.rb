# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'osctld/cgroup/group_cpu_bandwidth_policy'
require 'osctld/cgroup/param'

RSpec.describe OsCtld::CGroup::GroupCpuBandwidthPolicy do
  attr_reader :tmpdir, :parent_group, :child_group, :container, :writes,
              :rejections

  def param(name, value, version: 1)
    OsCtld::CGroup::Param.new(
      version,
      'cpu',
      name,
      [value],
      true
    )
  end

  def v1_params(quota, period = 100_000)
    ParamSet.new(
      [
        param(Policy::PERIOD_PARAMETER, period),
        param(Policy::QUOTA_PARAMETER, quota)
      ]
    )
  end

  def empty_params
    ParamSet.new([])
  end

  def create_cgroup(path, quota:, period: 100_000)
    absolute = File.join(tmpdir, path)
    FileUtils.mkdir_p(absolute)
    File.write(
      File.join(absolute, Policy::QUOTA_PARAMETER),
      quota.to_s
    )
    File.write(
      File.join(absolute, Policy::PERIOD_PARAMETER),
      period.to_s
    )
    absolute
  end

  def state(path)
    absolute = File.join(tmpdir, path)
    [
      File.read(File.join(absolute, Policy::QUOTA_PARAMETER)).to_i,
      File.read(File.join(absolute, Policy::PERIOD_PARAMETER)).to_i
    ]
  end

  def bandwidth(value)
    quota, period = value
    quota < 0 ? nil : Rational(quota, period)
  end

  def valid_v1_write?(path, proposed)
    proposed_bandwidth = bandwidth(proposed)
    return true unless proposed_bandwidth

    parent = File.dirname(path)
    while parent.start_with?(tmpdir)
      quota_file = File.join(parent, Policy::QUOTA_PARAMETER)
      if File.exist?(quota_file)
        parent_bandwidth = bandwidth(
          [
            File.read(quota_file).to_i,
            File.read(
              File.join(parent, Policy::PERIOD_PARAMETER)
            ).to_i
          ]
        )
        return false \
          if parent_bandwidth && proposed_bandwidth > parent_bandwidth
      end
      break if parent == tmpdir

      parent = File.dirname(parent)
    end

    Dir.glob(File.join(path, '**', Policy::QUOTA_PARAMETER)).all? do |file|
      child = File.dirname(file)
      next true if child == path

      child_bandwidth = bandwidth(
        [
          File.read(file).to_i,
          File.read(File.join(child, Policy::PERIOD_PARAMETER)).to_i
        ]
      )
      child_bandwidth.nil? || child_bandwidth <= proposed_bandwidth
    end
  end

  before do
    stub_const('Policy', OsCtld::CGroup::CpuBandwidthPolicy)
    stub_const(
      'ParamSet',
      Struct.new(:params) do
        def each(&)
          params.each(&)
        end

        def detect(&)
          params.detect(&)
        end
      end
    )
    stub_const(
      'TestGroup',
      Struct.new(
        :cgroup_path,
        :cgparams,
        :descendants,
        :containers_in_subtree
      )
    )
    stub_const(
      'TestContainer',
      Struct.new(
        :base_cgroup_path,
        :cgparams,
        :lifecycle
      )
    )
    stub_const('TestLifecycle', Struct.new(:runs))

    @tmpdir = Dir.mktmpdir('osctld-group-cpu-bandwidth-')
    @writes = []
    @rejections = []
    @parent_group = TestGroup.new(
      'group.parent',
      v1_params(400_000),
      [],
      []
    )
    @child_group = TestGroup.new(
      'group.parent/group.child',
      empty_params,
      [],
      []
    )
    @container = TestContainer.new(
      'group.parent/group.child/ct.one',
      empty_params,
      TestLifecycle.new({})
    )
    parent_group.descendants = [child_group]
    parent_group.containers_in_subtree = [container]
    child_group.containers_in_subtree = [container]

    create_cgroup('', quota: -1)
    create_cgroup(parent_group.cgroup_path, quota: 400_000)
    create_cgroup(child_group.cgroup_path, quota: -1)
    create_cgroup(container.base_cgroup_path, quota: -1)

    allow(OsCtld::CGroup).to receive_messages(
      version: 1,
      v1?: true,
      v2?: false,
      mkpath: false
    )
    allow(OsCtld::CGroup).to receive(:abs_cgroup_path) do |_subsystem, path|
      File.join(tmpdir, path)
    end
    allow(OsCtld::CGroup).to receive(:set_param) do |path, values|
      value = values.last.to_i
      cgroup = File.dirname(path)
      parameter = File.basename(path)
      current = state(cgroup.delete_prefix("#{tmpdir}/"))
      proposed =
        if parameter == Policy::QUOTA_PARAMETER
          [value, current.last]
        else
          [current.first, value]
        end
      writes << [
        cgroup.delete_prefix("#{tmpdir}/"),
        parameter,
        value
      ]
      rejected = rejections.delete(
        [cgroup.delete_prefix("#{tmpdir}/"), parameter, value]
      )
      next false if rejected || !valid_v1_write?(cgroup, proposed)

      File.write(path, value.to_s)
      true
    end
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  it 'restricts configured container boundaries before their group parent' do
    container.cgparams = v1_params(200_000)
    create_cgroup(container.base_cgroup_path, quota: 400_000)
    parent_group.cgparams = v1_params(250_000)

    described_class.new(parent_group).apply

    expect(writes).to eq(
      [
        [
          container.base_cgroup_path,
          Policy::QUOTA_PARAMETER,
          200_000
        ],
        [
          parent_group.cgroup_path,
          Policy::QUOTA_PARAMETER,
          250_000
        ]
      ]
    )
    expect(state(parent_group.cgroup_path)).to eq([250_000, 100_000])
    expect(state(container.base_cgroup_path)).to eq([200_000, 100_000])
  end

  it 'expands parents before configured finite children' do
    File.write(
      File.join(tmpdir, parent_group.cgroup_path, Policy::QUOTA_PARAMETER),
      '250000'
    )
    child_group.cgparams = v1_params(300_000)
    create_cgroup(child_group.cgroup_path, quota: 250_000)

    described_class.new(parent_group).apply

    expect(writes).to eq(
      [
        [
          parent_group.cgroup_path,
          Policy::QUOTA_PARAMETER,
          400_000
        ],
        [
          child_group.cgroup_path,
          Policy::QUOTA_PARAMETER,
          300_000
        ]
      ]
    )
  end

  it 'rejects a wider configured v1 child before creating paths or writing' do
    parent_group.cgparams = v1_params(250_000)
    child_group.cgparams = v1_params(400_000)

    expect do
      described_class.new(
        parent_group,
        reconstruct_to: parent_group
      ).apply
    end.to raise_error(
      Policy::Error,
      %r{configured CPU bandwidth 400000/100000.*exceeds prospective parent}
    )

    expect(OsCtld::CGroup).not_to have_received(:mkpath)
    expect(writes).to be_empty
    expect(state(parent_group.cgroup_path)).to eq([400_000, 100_000])
  end

  it 'rejects an impossible live pair before creating paths or writing' do
    parent_group.cgparams = v1_params(500_000, 200_000)

    expect do
      described_class.new(
        parent_group,
        reconstruct_to: parent_group
      ).apply
    end.to raise_error(
      Policy::Error,
      /cannot transition CPU bandwidth monotonically.*while live/
    )

    expect(OsCtld::CGroup).not_to have_received(:mkpath)
    expect(writes).to be_empty
    expect(state(parent_group.cgroup_path)).to eq([400_000, 100_000])
  end

  it 'allows an unlimited v1 child below a finite parent' do
    parent_group.cgparams = v1_params(250_000)

    described_class.new(parent_group).apply

    expect(state(parent_group.cgroup_path)).to eq([250_000, 100_000])
    expect(state(child_group.cgroup_path)).to eq([-1, 100_000])
  end

  it 'preserves the live period for a quota-only v1 configuration' do
    create_cgroup(
      parent_group.cgroup_path,
      quota: 400_000,
      period: 200_000
    )
    parent_group.cgparams = ParamSet.new(
      [param(Policy::QUOTA_PARAMETER, 250_000)]
    )

    described_class.new(parent_group).apply

    expect(state(parent_group.cgroup_path)).to eq([250_000, 200_000])
  end

  it 'preserves the live quota for a period-only v1 configuration' do
    parent_group.cgparams = ParamSet.new(
      [param(Policy::PERIOD_PARAMETER, 200_000)]
    )

    described_class.new(parent_group).apply

    expect(state(parent_group.cgroup_path)).to eq([400_000, 200_000])
  end

  it 'resets a removed v1 quota while retaining the configured period' do
    create_cgroup(
      parent_group.cgroup_path,
      quota: 400_000,
      period: 200_000
    )
    parent_group.cgparams = ParamSet.new(
      [param(Policy::PERIOD_PARAMETER, 250_000)]
    )

    described_class.new(
      parent_group,
      resets: [param(Policy::QUOTA_PARAMETER, 400_000)]
    ).apply

    expect(state(parent_group.cgroup_path)).to eq([-1, 250_000])
  end

  it 'resets a removed v1 period while retaining the configured quota' do
    create_cgroup(
      parent_group.cgroup_path,
      quota: 400_000,
      period: 200_000
    )
    parent_group.cgparams = ParamSet.new(
      [param(Policy::QUOTA_PARAMETER, 500_000)]
    )

    described_class.new(
      parent_group,
      resets: [param(Policy::PERIOD_PARAMETER, 200_000)]
    ).apply

    expect(state(parent_group.cgroup_path)).to eq([500_000, 100_000])
  end

  it 'creates only the requested missing group CPU root for mutation' do
    FileUtils.remove_entry(File.join(tmpdir, parent_group.cgroup_path))
    parent_group.cgparams = v1_params(250_000)
    allow(OsCtld::CGroup).to receive(:mkpath) do |controller, path, leaf:|
      expect(controller).to eq('cpu')
      expect(path.join('/')).to eq(parent_group.cgroup_path)
      expect(leaf).to be(false)
      create_cgroup(parent_group.cgroup_path, quota: -1)
    end

    described_class.new(
      parent_group,
      reconstruct_to: parent_group
    ).apply

    expect(state(parent_group.cgroup_path)).to eq([250_000, 100_000])
    expect(
      File.exist?(File.join(tmpdir, child_group.cgroup_path))
    ).to be(false)
  end

  it 'reconstructs a requested descendant without creating its sibling' do
    live_sibling = TestGroup.new(
      'group.parent/group.sibling',
      v1_params(300_000),
      [],
      []
    )
    stopped_sibling = TestGroup.new(
      'group.parent/group.stopped',
      v1_params(200_000),
      [],
      []
    )
    parent_group.descendants = [
      child_group,
      live_sibling,
      stopped_sibling
    ]
    create_cgroup(live_sibling.cgroup_path, quota: 400_000)
    FileUtils.remove_entry(File.join(tmpdir, child_group.cgroup_path))
    allow(OsCtld::CGroup).to receive(:mkpath) do |controller, path, leaf:|
      expect(controller).to eq('cpu')
      expect(path.join('/')).to eq(child_group.cgroup_path)
      expect(leaf).to be(false)
      create_cgroup(child_group.cgroup_path, quota: -1)
    end

    policy = described_class.new(
      parent_group,
      reconstruct_to: child_group
    )
    expect(policy.applied?).to be(false)

    policy.apply

    expect(OsCtld::CGroup).to have_received(:mkpath).once
    expect(state(live_sibling.cgroup_path)).to eq([300_000, 100_000])
    expect(
      File.exist?(File.join(tmpdir, stopped_sibling.cgroup_path))
    ).to be(false)
  end

  it 'preflights but skips an absent stopped container policy root' do
    container.cgparams = v1_params(200_000)
    FileUtils.remove_entry(File.join(tmpdir, container.base_cgroup_path))
    parent_group.cgparams = v1_params(250_000)

    described_class.new(parent_group).apply

    expect(state(parent_group.cgroup_path)).to eq([250_000, 100_000])
    expect(
      File.exist?(File.join(tmpdir, container.base_cgroup_path))
    ).to be(false)
  end

  it 'treats a raw unlimited residual as applied behind an unchanged cap' do
    residual = "#{container.base_cgroup_path}/runs/residual"
    create_cgroup(parent_group.cgroup_path, quota: 250_000)
    create_cgroup(residual, quota: -1)
    parent_group.cgparams = v1_params(250_000)
    container.lifecycle.runs['residual'] = {
      'role' => 'residual',
      'resources' => {
        'cgroup_root' => residual
      }
    }

    expect(described_class.new(parent_group).applied?).to be(true)
    expect(writes).to be_empty
  end

  it 'pins residuals before expanding their group ancestor' do
    residual = "#{container.base_cgroup_path}/runs/residual"
    create_cgroup(parent_group.cgroup_path, quota: 250_000)
    create_cgroup(residual, quota: -1)
    container.lifecycle.runs['residual'] = {
      'role' => 'residual',
      'resources' => {
        'cgroup_root' => residual
      }
    }

    described_class.new(parent_group).apply

    residual_write = writes.index(
      [residual, Policy::QUOTA_PARAMETER, 250_000]
    )
    parent_write = writes.index(
      [parent_group.cgroup_path, Policy::QUOTA_PARAMETER, 400_000]
    )
    expect(residual_write).to be < parent_write
    expect(state(residual)).to eq([250_000, 100_000])
  end

  it 'rolls the complete group hierarchy back after a rejected write' do
    container.cgparams = v1_params(200_000)
    create_cgroup(container.base_cgroup_path, quota: 400_000)
    parent_group.cgparams = v1_params(250_000)
    rejections << [
      parent_group.cgroup_path,
      Policy::QUOTA_PARAMETER,
      250_000
    ]

    expect do
      described_class.new(parent_group).apply
    end.to raise_error(
      Policy::Error,
      /kernel rejected cpu\.cfs_quota_us=250000/
    )

    expect(state(parent_group.cgroup_path)).to eq([400_000, 100_000])
    expect(state(container.base_cgroup_path)).to eq([400_000, 100_000])
  end

  it 'exposes exact compensation after a later transaction failure' do
    residual = "#{container.base_cgroup_path}/runs/residual"
    create_cgroup(parent_group.cgroup_path, quota: 250_000)
    create_cgroup(residual, quota: -1)
    container.lifecycle.runs['residual'] = {
      'role' => 'residual',
      'resources' => {
        'cgroup_root' => residual
      }
    }

    result = described_class.new(parent_group).apply
    result.rollback!

    expect(state(parent_group.cgroup_path)).to eq([250_000, 100_000])
    expect(state(residual)).to eq([-1, 100_000])
  end

  it 'reports reconstruction as non-compensable after a later failure' do
    parent_group.cgparams = v1_params(250_000)

    result = described_class.new(
      parent_group,
      reconstruct_to: parent_group
    ).apply

    expect do
      result.rollback!
    end.to raise_error(
      Policy::Error,
      /reconstruction cannot be rolled back exactly/
    )
    expect(state(parent_group.cgroup_path)).to eq([400_000, 100_000])
  end

  it 'reports failed reconstruction transactions as non-compensable' do
    FileUtils.remove_entry(File.join(tmpdir, parent_group.cgroup_path))
    parent_group.cgparams = v1_params(250_000)
    allow(OsCtld::CGroup).to receive(:mkpath) do |_controller, _path, leaf:|
      expect(leaf).to be(false)
      create_cgroup(parent_group.cgroup_path, quota: -1)
    end
    rejections << [
      parent_group.cgroup_path,
      Policy::QUOTA_PARAMETER,
      250_000
    ]

    error =
      begin
        described_class.new(
          parent_group,
          reconstruct_to: parent_group
        ).apply
        nil
      rescue Policy::Error => e
        e
      end

    expect(error).not_to be_nil
    expect(error.rollback_error).to be_a(Policy::Error)
    expect(error.message).to match(
      /reconstruction cannot be rolled back exactly/
    )
  end

  it 'reports an exact group hierarchy rollback failure' do
    container.cgparams = v1_params(200_000)
    create_cgroup(container.base_cgroup_path, quota: 400_000)
    parent_group.cgparams = v1_params(250_000)
    rejections.push(
      [
        parent_group.cgroup_path,
        Policy::QUOTA_PARAMETER,
        250_000
      ],
      [
        container.base_cgroup_path,
        Policy::QUOTA_PARAMETER,
        400_000
      ]
    )

    expect do
      described_class.new(parent_group).apply
    end.to raise_error(
      Policy::Error,
      /rollback failed: kernel rejected cpu\.cfs_quota_us=400000/
    )

    expect(state(parent_group.cgroup_path)).to eq([400_000, 100_000])
    expect(state(container.base_cgroup_path)).to eq([200_000, 100_000])
  end

  context 'with cgroup v2' do
    def v2_params(value)
      ParamSet.new([param(Policy::V2_PARAMETER, value, version: 2)])
    end

    def create_v2_cgroup(path, value)
      absolute = File.join(tmpdir, path)
      FileUtils.mkdir_p(absolute)
      File.write(File.join(absolute, Policy::V2_PARAMETER), value)
    end

    def v2_state(path)
      File.read(File.join(tmpdir, path, Policy::V2_PARAMETER)).strip
    end

    before do
      allow(OsCtld::CGroup).to receive_messages(
        version: 2,
        v1?: false,
        v2?: true
      )
      FileUtils.rm_rf(File.join(tmpdir, parent_group.cgroup_path))
      create_v2_cgroup('', 'max 100000')
      create_v2_cgroup(parent_group.cgroup_path, '250000 100000')
      create_v2_cgroup(child_group.cgroup_path, '400000 100000')
      create_v2_cgroup(container.base_cgroup_path, 'max 100000')
      parent_group.cgparams = v2_params('250000 100000')
      child_group.cgparams = v2_params('400000 100000')
      writes.clear
      allow(OsCtld::CGroup).to receive(:set_param) do |path, values|
        value = values.last.to_s
        relative = File.dirname(path).delete_prefix("#{tmpdir}/")
        write = [
          relative,
          File.basename(path),
          value
        ]
        writes << write
        next false if rejections.delete(write)

        File.write(path, value)
        true
      end
    end

    it 'retains a wider finite child behind its parent effective cap' do
      expect(described_class.new(parent_group).applied?).to be(true)

      parent_group.cgparams = v2_params('300000 100000')
      described_class.new(parent_group).apply

      expect(v2_state(parent_group.cgroup_path)).to eq('300000 100000')
      expect(v2_state(child_group.cgroup_path)).to eq('400000 100000')
    end

    it 'pins a residual before expanding its v2 group ancestor' do
      residual = "#{container.base_cgroup_path}/runs/residual"
      create_v2_cgroup(residual, 'max 100000')
      container.lifecycle.runs['residual'] = {
        'role' => 'residual',
        'resources' => {
          'cgroup_root' => residual
        }
      }
      parent_group.cgparams = v2_params('300000 100000')

      described_class.new(parent_group).apply

      residual_write = writes.index(
        [residual, Policy::V2_PARAMETER, '250000 100000']
      )
      parent_write = writes.index(
        [
          parent_group.cgroup_path,
          Policy::V2_PARAMETER,
          '300000 100000'
        ]
      )
      expect(residual_write).to be < parent_write
      expect(v2_state(residual)).to eq('250000 100000')
    end

    it 'restores a broad v2 residual request when expansion fails' do
      residual = "#{container.base_cgroup_path}/runs/residual"
      create_v2_cgroup(residual, 'max 100000')
      container.lifecycle.runs['residual'] = {
        'role' => 'residual',
        'resources' => {
          'cgroup_root' => residual
        }
      }
      parent_group.cgparams = v2_params('300000 100000')
      rejections << [
        parent_group.cgroup_path,
        Policy::V2_PARAMETER,
        '300000 100000'
      ]

      expect do
        described_class.new(parent_group).apply
      end.to raise_error(
        Policy::Error,
        /kernel rejected cpu\.max=300000 100000/
      )

      expect(v2_state(parent_group.cgroup_path)).to eq('250000 100000')
      expect(v2_state(residual)).to eq('max 100000')
    end

    it 'externally compensates a successful v2 residual pin exactly' do
      residual = "#{container.base_cgroup_path}/runs/residual"
      create_v2_cgroup(residual, 'max 100000')
      container.lifecycle.runs['residual'] = {
        'role' => 'residual',
        'resources' => {
          'cgroup_root' => residual
        }
      }
      parent_group.cgparams = v2_params('300000 100000')

      result = described_class.new(parent_group).apply
      result.rollback!

      expect(v2_state(parent_group.cgroup_path)).to eq('250000 100000')
      expect(v2_state(residual)).to eq('max 100000')
    end
  end
end
