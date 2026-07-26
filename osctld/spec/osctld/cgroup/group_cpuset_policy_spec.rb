# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'osctld/cgroup/group_cpuset_policy'

RSpec.describe OsCtld::CGroup::GroupCpusetPolicy do
  let(:cgroup_fs) { Dir.mktmpdir('osctld-group-cpuset-policy') }
  let(:writes) { [] }
  let(:test_classes) do
    {
      param_set: Struct.new(:param) do
        def detect(&)
          [param].detect(&)
        end
      end,
      group: Struct.new(:cgroup_path, :cgparams, :descendants)
    }
  end
  let(:parent_group) do
    test_classes.fetch(:group).new(
      '/osctl/pool.tank/group.parent',
      test_classes.fetch(:param_set).new(cpuset_param('0-5')),
      []
    )
  end
  let(:child_group) do
    test_classes.fetch(:group).new(
      '/osctl/pool.tank/group.parent/group.child',
      test_classes.fetch(:param_set).new(cpuset_param('2-4')),
      []
    )
  end

  before do
    parent_group.descendants = [child_group]
    allow(OsCtld::CGroup).to receive_messages(version: 1, v2?: false)
    allow(OsCtld::CGroup).to receive(:abs_cgroup_path) do |subsystem, path|
      File.join(cgroup_fs, subsystem, path)
    end
    allow(OsCtld::CGroup).to receive(:mkpath)
    allow(OsCtld::CGroup).to receive(:set_param) do |path, values|
      mask = values.last.to_s.strip
      writes << [
        File.dirname(path).delete_prefix("#{cgroup_fs}/cpuset"),
        mask
      ]
      next false unless valid_write?(File.dirname(path), mask)

      File.write(path, values.last)
      recompute_effective_masks
      true
    end

    create_cgroup('', '0-7')
    create_cgroup('/osctl', '0-7')
    create_cgroup('/osctl/pool.tank', '0-7')
    create_cgroup(parent_group.cgroup_path, '0-7')
    create_cgroup(child_group.cgroup_path, '0-7')
    create_cgroup("#{child_group.cgroup_path}/user.test", '0-7')
    recompute_effective_masks
  end

  after do
    FileUtils.rm_rf(cgroup_fs)
  end

  it 'reconstructs inherited v1 children before narrowing their parents' do
    expect(described_class.new(parent_group).apply).to be(true)

    expect(configured(parent_group.cgroup_path)).to eq('0-5')
    expect(configured(child_group.cgroup_path)).to eq('2-4')
    expect(configured("#{child_group.cgroup_path}/user.test")).to eq('2-4')
    expect(write_index("#{child_group.cgroup_path}/user.test", '2-4'))
      .to be < write_index(child_group.cgroup_path, '2-4')
    expect(write_index(child_group.cgroup_path, '2-4'))
      .to be < write_index(parent_group.cgroup_path, '0-5')
  end

  it 'recognizes an already-applied group hierarchy without writing' do
    described_class.new(parent_group).apply
    writes.clear

    expect(described_class.new(parent_group).applied?).to be(true)
    expect(writes).to be_empty
  end

  def cpuset_param(mask)
    OsCtld::CGroup::Param.new(
      1,
      'cpuset',
      'cpuset.cpus',
      [mask],
      true
    )
  end

  def create_cgroup(path, mask)
    absolute = File.join(cgroup_fs, 'cpuset', path)
    FileUtils.mkdir_p(absolute)
    File.write(File.join(absolute, 'cpuset.cpus'), mask)
    File.write(File.join(absolute, 'cpuset.cpus.effective'), mask)
  end

  def configured(path)
    File.read(
      File.join(cgroup_fs, 'cpuset', path, 'cpuset.cpus')
    ).strip
  end

  def effective(path)
    File.read(
      File.join(cgroup_fs, 'cpuset', path, 'cpuset.cpus.effective')
    ).strip
  end

  def valid_write?(path, mask)
    return true if mask.empty?

    selected = OsCtl::Lib::CpuMask.new(mask).to_a
    parent = File.dirname(path)
    unless path == File.join(cgroup_fs, 'cpuset')
      parent_mask = OsCtl::Lib::CpuMask.new(
        File.read(File.join(parent, 'cpuset.cpus')).strip
      ).to_a
      return false unless (selected - parent_mask).empty?
    end

    Dir.glob(File.join(path, '*', 'cpuset.cpus')).all? do |file|
      child = OsCtl::Lib::CpuMask.new(File.read(file).strip).to_a
      (child - selected).empty?
    end
  end

  def recompute_effective_masks
    files = Dir.glob(File.join(cgroup_fs, 'cpuset', '**', 'cpuset.cpus'))
    files.sort_by { |path| path.count('/') }.each do |file|
      path = File.dirname(file)
      explicit = OsCtl::Lib::CpuMask.new(File.read(file).strip).to_a
      inherited =
        if path == File.join(cgroup_fs, 'cpuset')
          explicit
        else
          relative_path = path.delete_prefix("#{cgroup_fs}/cpuset")
          parent_mask = effective(File.dirname(relative_path))
          OsCtl::Lib::CpuMask.new(parent_mask).to_a
        end
      value = OsCtl::Lib::CpuMask.format(explicit & inherited)
      File.write(File.join(path, 'cpuset.cpus.effective'), value)
    end
  end

  def write_index(path, mask)
    writes.index([path, mask])
  end
end
