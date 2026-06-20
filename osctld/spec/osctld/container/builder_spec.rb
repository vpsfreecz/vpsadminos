# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles

require 'osctld/utils/switch_user'
require 'osctld/container/dataset_builder'
require 'osctld/container/builder'

RSpec.describe OsCtld::Container::Builder do
  let(:pool) { double(name: 'tank') }
  let(:user) { double(ugid: 1000) }
  let(:root) { Dir.mktmpdir('builder-root') }
  let(:group) do
    double(
      setup_for?: false,
      userdir: File.join(root, 'group-userdir'),
      has_containers?: false,
      full_cgroup_path: '/osctl/tank/user.alice'
    )
  end
  let(:dataset) { double(on_pool?: true, mount: nil, to_s: 'tank/ct/ct1') }
  let(:ct) do
    double(
      configure: nil,
      configure_bashrc: nil,
      lxc_config: double(configure: nil),
      user_hook_script_dir: File.join(root, 'hooks'),
      base_cgroup_path: '/osctl/tank/ct.ct1',
      group: group
    )
  end
  let(:map_mode) { 'zfs' }
  let(:ctrc_attrs) do
    {
      pool: pool,
      user: user,
      group: group,
      id: 'ct1',
      dataset: dataset,
      uid_map: FakeObjects::FakeIdMap.new,
      gid_map: FakeObjects::FakeIdMap.new,
      map_mode: map_mode,
      rootfs: File.join(root, 'rootfs'),
      dir: File.join(root, 'ctdir'),
      lxc_dir: File.join(root, 'lxc'),
      ct: ct,
      log_path: File.join(root, 'ct.log'),
      config_path: File.join(root, 'ct.yml')
    }
  end
  let(:ctrc) { double(**ctrc_attrs) }
  let(:builder) { described_class.new(ctrc) }
  let(:ds_builder) { instance_double(OsCtld::Container::DatasetBuilder) }

  before do
    builder.instance_variable_set('@ds_builder', ds_builder)
    stub_const(
      'OsCtld::DB::Containers',
      Class.new do
        def self.contains?(*); end
        def self.sync(&block) = block.call
        def self.add(*); end
        def self.remove(*); end
      end
    )
    stub_const(
      'OsCtld::Console',
      Class.new do
        def self.remove(*); end
      end
    )
    stub_const(
      'OsCtld::CGroup',
      Class.new do
        def self.rmpath_all(*); end
      end
    )

    allow(OsCtld::DB::Containers).to receive(:contains?).and_return(false)
    allow(OsCtld::DB::Containers).to receive(:add)
    allow(OsCtld::DB::Containers).to receive(:remove)
    allow(OsCtld::Console).to receive(:remove)
    allow(OsCtld::CGroup).to receive(:rmpath_all)
    allow(File).to receive(:chown)
    allow(builder).to receive(:zfs)
    allow(builder).to receive(:syscmd) do |cmd|
      system(cmd)
      double
    end
  end

  after do
    FileUtils.rm_rf(root)
  end

  it 'builds a container and run configuration wrapper via .create' do
    stub_const(
      'OsCtld::Container',
      Class.new do
        def self.default_dataset(*); end
        def self.new(*); end
      end
    )
    stub_const(
      'OsCtld::Container::DatasetBuilder',
      Class.new do
        def self.new(*)
          Object.new
        end
      end
    )
    stub_const(
      'OsCtld::Container::RunConfiguration',
      Class.new do
        def self.new(ct)
          [:run_config, ct]
        end
      end
    )
    allow(OsCtld::Container).to receive(:default_dataset).with(pool, 'ct1').and_return(dataset)
    allow(OsCtld::Container).to receive(:new).and_return(ct)

    created = described_class.create(pool, 'ct1', user, group, nil, map_mode: 'native')

    expect(created.ctrc).to eq([:run_config, ct])
    expect(OsCtld::Container).to have_received(:new).with(
      pool,
      'ct1',
      user,
      group,
      dataset,
      load: false,
      map_mode: 'native'
    )
  end

  it 'validates ids and pool datasets' do
    wrong_dataset = double(on_pool?: false, to_s: 'other/ct1')
    invalid = described_class.new(double(**ctrc_attrs, id: 'bad id', dataset: wrong_dataset))

    expect(invalid.valid?).to be(false)
    expect(invalid.errors).to include(a_string_matching(/invalid ID/))
    expect(invalid.errors).to include('dataset other/ct1 does not belong to pool tank')
  end

  it 'delegates dataset creation with mapping-aware options' do
    allow(ds_builder).to receive(:create_dataset)

    builder.create_dataset(
      dataset,
      mapping: true,
      parents: true,
      properties: { 'compression' => 'lz4' }
    )

    expect(ds_builder).to have_received(:create_dataset).with(
      dataset,
      parents: true,
      properties: { 'compression' => 'lz4' },
      uid_map: ctrc.uid_map,
      gid_map: ctrc.gid_map
    )
  end

  it 'registers under the host-link registry before locking the container list' do
    events = []
    allow(OsCtld::NetInterface).to receive(:sync_host_link_registry) do |&block|
      events << :host_links
      block.call
    end
    allow(OsCtld::DB::Containers).to receive(:sync) do |&block|
      events << :containers
      block.call
    end
    allow(OsCtld::DB::Containers).to receive(:add) { events << :add }

    expect(builder.register).to be(true)
    expect(events).to eq(%i[host_links containers add])
    expect(OsCtld::DB::Containers).to have_received(:contains?).with('ct1', pool)
    expect(OsCtld::DB::Containers).to have_received(:add).with(ct)
  end

  it 'shifts zfs datasets and mounts non-zfs datasets' do
    allow(ds_builder).to receive(:shift_dataset)

    builder.shift_or_mount_dataset

    expect(ds_builder).to have_received(:shift_dataset).with(
      dataset,
      uid_map: ctrc.uid_map,
      gid_map: ctrc.gid_map
    )

    non_zfs_dataset_builder = instance_double(OsCtld::Container::DatasetBuilder, shift_dataset: nil)
    non_zfs = described_class.new(double(**ctrc_attrs, map_mode: 'native'))
    non_zfs.instance_variable_set('@ds_builder', non_zfs_dataset_builder)
    allow(dataset).to receive(:mount)

    non_zfs.shift_or_mount_dataset

    expect(dataset).to have_received(:mount)
  end

  it 'prepares filesystem artifacts for a new container' do
    FileUtils.mkdir_p(root)

    builder.setup_rootfs
    builder.setup_lxc_home
    builder.setup_log_file
    builder.setup_user_hook_script_dir

    expect(File.stat(ctrc.rootfs).mode & 0o777).to eq(0o755)
    expect(File.stat(ctrc.lxc_dir).mode & 0o777).to eq(0o750)
    expect(File.exist?(ctrc.log_path)).to be(true)
    expect(File.exist?(ct.user_hook_script_dir)).to be(true)
    expect(ct).to have_received(:configure_bashrc)
  end

  it 'cleans up partially created containers' do
    FileUtils.mkdir_p(group.userdir(user))
    FileUtils.mkdir_p(ctrc.lxc_dir)
    File.write(File.join(ctrc.lxc_dir, '.bashrc'), '')
    FileUtils.mkdir_p(ct.user_hook_script_dir)
    File.write(ctrc.log_path, '')
    File.write(ctrc.config_path, '')

    builder.cleanup(dataset: true)

    expect(OsCtld::Console).to have_received(:remove).with(ct)
    expect(builder).to have_received(:zfs).with(:destroy, '-r', dataset, valid_rcs: [1])
    expect(OsCtld::DB::Containers).to have_received(:remove).with(ct)
    expect(OsCtld::CGroup).to have_received(:rmpath_all).with('/osctl/tank/user.alice')
    expect(File.exist?(ct.user_hook_script_dir)).to be(false)
    expect(File.exist?(ctrc.log_path)).to be(false)
    expect(File.exist?(ctrc.config_path)).to be(false)
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles
