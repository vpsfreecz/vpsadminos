# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'osctld/cgroup/cpuset_policy'

RSpec.describe OsCtld::CGroup::CpusetPolicy do
  let(:cgroup_fs) { Dir.mktmpdir('osctld-cpuset-policy') }
  let(:writes) { [] }
  let(:failed_write) { { value: nil } }
  let(:lifecycle_class) { Struct.new(:runs) }
  let(:container_class) { Struct.new(:base_cgroup_path, :lifecycle) }

  after do
    FileUtils.rm_rf(cgroup_fs)
  end

  before do
    allow(OsCtld::CGroup).to receive(:abs_cgroup_path) do |subsystem, *path|
      File.join(cgroup_fs, subsystem, *path)
    end
    allow(OsCtld::CGroup).to receive(:set_param) do |path, values|
      value = values.last.to_s
      relative = File.dirname(path).delete_prefix("#{cgroup_fs}/cpuset/")
      writes << [relative, value.strip]

      if failed_write[:value] == [relative, value.strip]
        failed_write[:value] = nil
        false
      else
        File.write(path, value)
        recompute_effective_masks
        forced_effective.each do |cgroup_path, mask|
          write_cgroup_file(cgroup_path, 'cpuset.cpus.effective', mask)
        end
        true
      end
    end
  end

  it 'restricts cgroup v1 leaves before the stable policy root' do
    ct = build_topology(active: '0-7')

    result = described_class.new(ct, '2-4').apply

    expect(result.target).to eq('2-4')
    expect(configured_mask(stable_path)).to eq('2-4')
    expect(configured_mask(active_inner_path)).to eq('2-4')
    expect(write_index(active_inner_path, '2-4'))
      .to be < write_index(stable_path, '2-4')
  end

  it 'expands cgroup v1 parents before their children' do
    ct = build_topology(active: '2,3')

    described_class.new(ct, '0-5').apply

    expect(writes.first).to eq([stable_path, '0-5'])
    expect(write_index(stable_path, '0-5'))
      .to be < write_index(active_inner_path, '0-5')
  end

  it 'uses an expansion and restriction phase for disjoint masks' do
    ct = build_topology(active: '0,1')

    described_class.new(ct, '4,5').apply

    expect(writes.first).to eq([stable_path, '0,1,4,5'])
    expect(write_index(active_inner_path, '4,5'))
      .to be < write_index(stable_path, '4,5')
    expect(configured_mask(stable_path)).to eq('4,5')
  end

  it 'sets an explicit cgroup v2 namespaced root mask' do
    ct = build_topology(active: '0-7', inherited_inner: true)

    described_class.new(ct, '2-4').apply

    expect(configured_mask(active_inner_path)).to eq('2-4')
    expect(effective_mask(active_inner_path)).to eq('2-4')
  end

  it 'validates against the effective parent mask instead of its request' do
    ct = build_topology(active: '2-4')
    write_cgroup_file(parent_path, 'cpuset.cpus', '0-7')
    write_cgroup_file(parent_path, 'cpuset.cpus.effective', '2-4')

    expect(
      described_class.read_effective_mask(
        File.join(cgroup_fs, 'cpuset', parent_path)
      )
    ).to eq('2-4')
    expect { described_class.new(ct, '5').apply }
      .to raise_error(
        described_class::Error,
        /cpuset mask 5 exceeds parent mask 2-4/
      )
    expect(writes).to be_empty
  end

  it 'rejects an empty effective grant even with a non-empty request' do
    ct = build_topology(active: '2-4')
    write_cgroup_file(parent_path, 'cpuset.cpus', '0-7')
    write_cgroup_file(parent_path, 'cpuset.cpus.effective', '')

    expect { described_class.new(ct, '2-4').apply }
      .to raise_error(
        described_class::Error,
        /effective mask is empty/
      )
    expect(writes).to be_empty
  end

  it 'rolls back when a hotplug-style effective grant changes mid-transaction' do
    ct = build_topology(active: '0-7')
    forced_effective[active_inner_path] = '2,3'

    expect { described_class.new(ct, '2-4').apply }
      .to raise_error(
        described_class::Error,
        /has effective mask 2,3, expected 2-4/
      )

    expect(configured_mask(stable_path)).to eq('0-7')
    expect(configured_mask(active_inner_path)).to eq('0-7')
  end

  it 'does not broaden a residual generation while expanding the policy' do
    ct = build_topology(
      active: '0,1',
      residual: '0,1',
      inherited_residual: true
    )

    result = described_class.new(ct, '0-5').apply

    expect(configured_mask(residual_root_path)).to eq('0,1')
    expect(effective_mask(residual_inner_path)).to eq('0,1')
    expect(result.run_masks.fetch('residual')).to eq('0,1')
    expect(result.run_masks.fetch('active')).to eq('0-5')
  end

  it 'caps every residual descendant by its pre-transaction effective mask' do
    ct = build_topology(active: '0-3', residual: '0-7')
    unknown = File.join(residual_inner_path, 'unknown-worker')
    create_cgroup(unknown, '0-7')
    recompute_effective_masks

    residual_paths = [
      residual_root_path,
      File.join(residual_root_path, 'user-owned'),
      generation_payload_path('residual'),
      residual_inner_path,
      unknown
    ]

    described_class.new(ct, '0-5').apply

    residual_paths.each do |path|
      expect(configured_mask(path)).to eq('0-3')
      expect(write_index(path, '0-3'))
        .to be < write_index(stable_path, '0-5')
    end
  end

  it 'rejects a policy disjoint from a residual generation' do
    ct = build_topology(active: '0,1', residual: '0,1')

    expect { described_class.new(ct, '4,5').apply }
      .to raise_error(
        described_class::Error,
        /residual cgroup .* cannot be restricted/
      )

    expect(configured_mask(stable_path)).to eq('0,1')
    expect(configured_mask(residual_root_path)).to eq('0,1')
  end

  it 'rolls the hierarchy back when the kernel rejects a final write' do
    ct = build_topology(active: '0-3')
    failed_write[:value] = [stable_path, '2,3']

    error = nil
    begin
      described_class.new(ct, '2,3').apply
    rescue described_class::Error => e
      error = e
    end

    expect(error).not_to be_nil
    expect(error.rollback_error).to be_nil
    expect(configured_mask(stable_path)).to eq('0-3')
    expect(configured_mask(active_inner_path)).to eq('0-3')
  end

  it 'rolls back when post-write generation bookkeeping fails' do
    ct = build_topology(active: '0-3')
    policy = described_class.new(ct, '2,3')
    allow(policy).to receive(:generation_masks)
      .and_raise(described_class::Error, 'generation mask disappeared')

    error = nil
    begin
      policy.apply
    rescue described_class::Error => e
      error = e
    end

    expect(error.message).to match(/generation mask disappeared/)
    expect(error.rollback_error).to be_nil
    expect(configured_mask(stable_path)).to eq('0-3')
    expect(configured_mask(active_inner_path)).to eq('0-3')
  end

  it 'restores residual requests only after their old ancestor cap' do
    ct = build_topology(active: '0-3', residual: '0-7')
    failed_write[:value] = [stable_path, '2-5']

    expect { described_class.new(ct, '2-5').apply }
      .to raise_error(described_class::Error, /kernel rejected cpuset mask/)

    stable_restore = writes.rindex([stable_path, '0-3'])
    expect(stable_restore).not_to be_nil
    [
      residual_root_path,
      File.join(residual_root_path, 'user-owned'),
      generation_payload_path('residual'),
      residual_inner_path
    ].each do |path|
      expect(writes.rindex([path, '0-7'])).to be > stable_restore
      expect(configured_mask(path)).to eq('0-7')
      expect(effective_mask(path)).to eq('0-3')
    end
  end

  it 'rejects malformed masks before changing the hierarchy' do
    ct = build_topology(active: '0-3')

    expect { described_class.new(ct, '2-nope') }
      .to raise_error(described_class::Error, /invalid cpuset mask/)
    expect(writes).to be_empty
  end

  def build_topology(
    active:,
    residual: nil,
    inherited_inner: false,
    inherited_residual: false
  )
    create_cgroup(parent_path, '0-7')
    create_cgroup(stable_path, active)
    create_cgroup(File.join(stable_path, 'runs'), active)
    create_generation(
      'active',
      active,
      inherited_inner:
    )

    runs = {
      'active' => lifecycle_run('active', :active)
    }

    if residual
      create_generation(
        'residual',
        residual,
        inherited_inner: inherited_residual
      )
      runs['residual'] = lifecycle_run('residual', :residual)
    end

    recompute_effective_masks
    container_class.new(
      '/osctl/pool.tank/ct.ct1',
      lifecycle_class.new(runs)
    )
  end

  def create_generation(name, mask, inherited_inner:)
    [
      generation_root_path(name),
      File.join(generation_root_path(name), 'user-owned'),
      generation_payload_path(name)
    ].each { |path| create_cgroup(path, mask) }

    create_cgroup(
      generation_inner_path(name),
      inherited_inner ? '' : mask
    )
  end

  def lifecycle_run(name, role)
    root = "/osctl/pool.tank/ct.ct1/runs/#{name}"
    {
      'role' => role.to_s,
      'resources' => {
        'cgroup_root' => root,
        'user_cgroup' => File.join(root, 'user-owned'),
        'lxc_payload' => File.join(root, 'user-owned', 'payload'),
        'lxc_inner' => File.join(root, 'user-owned', 'payload', 'inner')
      }
    }
  end

  def create_cgroup(relative, mask)
    path = File.join(cgroup_fs, 'cpuset', relative)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'cpuset.cpus'), mask)
    File.write(File.join(path, 'cpuset.cpus.effective'), mask)
  end

  def write_cgroup_file(relative, name, value)
    File.write(File.join(cgroup_fs, 'cpuset', relative, name), value)
  end

  def forced_effective
    @forced_effective ||= {}
  end

  def recompute_effective_masks
    paths = Dir.glob(
      File.join(cgroup_fs, 'cpuset', '**', 'cpuset.cpus')
    ).map { |path| File.dirname(path) }
    paths.sort_by! { |path| [path.count('/'), path] }

    paths.each do |path|
      explicit = File.read(File.join(path, 'cpuset.cpus')).strip
      parent = File.dirname(path)
      parent_effective =
        if File.exist?(File.join(parent, 'cpuset.cpus.effective'))
          parse_mask(File.read(File.join(parent, 'cpuset.cpus.effective')).strip)
        end
      effective =
        if explicit.empty?
          parent_effective || []
        elsif parent_effective
          parse_mask(explicit) & parent_effective
        else
          parse_mask(explicit)
        end

      File.write(
        File.join(path, 'cpuset.cpus.effective'),
        OsCtl::Lib::CpuMask.format(effective).to_s
      )
    end
  end

  def parse_mask(value)
    OsCtl::Lib::CpuMask.new(value).to_a
  end

  def configured_mask(relative)
    File.read(
      File.join(cgroup_fs, 'cpuset', relative, 'cpuset.cpus')
    ).strip
  end

  def effective_mask(relative)
    File.read(
      File.join(cgroup_fs, 'cpuset', relative, 'cpuset.cpus.effective')
    ).strip
  end

  def write_index(relative, value)
    writes.index([relative, value])
  end

  def parent_path
    'osctl/pool.tank'
  end

  def stable_path
    'osctl/pool.tank/ct.ct1'
  end

  def generation_root_path(name)
    File.join(stable_path, 'runs', name)
  end

  def generation_payload_path(name)
    File.join(generation_root_path(name), 'user-owned', 'payload')
  end

  def generation_inner_path(name)
    File.join(generation_payload_path(name), 'inner')
  end

  def active_inner_path
    generation_inner_path('active')
  end

  def residual_root_path
    generation_root_path('residual')
  end

  def residual_inner_path
    generation_inner_path('residual')
  end
end
