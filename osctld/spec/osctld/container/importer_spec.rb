# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles

require 'yaml'

require 'osctld/container/importer'

RSpec.describe OsCtld::Container::Importer do
  let(:pool) { FakeObjects::FakePool.new(name: 'tank') }
  let(:metadata) do
    {
      'format' => 'tar',
      'user' => 'alice',
      'group' => '/default',
      'container' => 'ct1',
      'datasets' => %w[var log]
    }
  end
  let(:archive) do
    build_tar([
                { name: 'metadata.yml', body: metadata.to_yaml },
                { name: 'config/user.yml', body: { ugid: 1000 }.to_yaml },
                { name: 'config/group.yml', body: { path: '/default' }.to_yaml },
                { name: 'config/container.yml', body: { 'distribution' => 'alpine' }.to_yaml },
                { name: 'hooks', type: :directory, mode: 0o755 },
                { name: 'hooks/pre-start', body: "#!/bin/sh\nexit 0\n", mode: 0o755 },
                { name: 'rootfs/base.tar.gz', body: 'rootfs' }
              ])
  end
  let(:importer) { described_class.new(pool, archive, image_file: '/tmp/archive.tar') }

  before do
    stub_const('OsCtld::User', Class.new)
    stub_const('OsCtld::Group', Class.new)
    stub_const(
      'OsCtld::DB::Users',
      Class.new do
        def self.find(*); end
      end
    )
    stub_const(
      'OsCtld::DB::Groups',
      Class.new do
        def self.find(*); end
        def self.default(*) = :default_group
      end
    )
    stub_const(
      'OsCtld::Commands::User::Create',
      Class.new do
        def self.run!(*); end
      end
    )
    stub_const(
      'OsCtld::Commands::Group::Create',
      Class.new do
        def self.run!(*); end
      end
    )
    stub_const(
      'OsCtld::UGidRegistry',
      Class.new do
        def self.remove(*); end
      end
    )
    allow(OsCtld::Commands::User::Create).to receive(:run!)
    allow(OsCtld::Commands::Group::Create).to receive(:run!)
    allow(OsCtld::UGidRegistry).to receive(:remove)
  end

  it 'loads metadata and helper accessors from the archive' do
    expect(importer.load_metadata).to include('container' => 'ct1')
    expect(importer.user_name).to eq('alice')
    expect(importer.group_name).to eq('/default')
    expect(importer.ct_id).to eq('ct1')
    expect(importer.has_user?).to be(true)
    expect(importer.has_group?).to be(true)
    expect(importer.has_ct_id?).to be(true)
    expect(importer.get_container_config).to eq('distribution' => 'alpine')
  end

  it 'creates a missing imported user and returns a matching existing one' do
    importer.load_metadata
    imported_user = FakeObjects::FakeUser.new(name: 'alice', userdir: '/userdir', ugid: 1234)
    existing_user = FakeObjects::FakeUser.new(name: 'alice', userdir: '/userdir', ugid: 1234)

    allow(importer).to receive(:load_user).and_return(imported_user)
    allow(OsCtld::DB::Users).to receive(:find).with('alice', pool).and_return(nil, imported_user)

    expect(importer.get_or_create_user).to eq(imported_user)
    expect(OsCtld::Commands::User::Create).to have_received(:run!).with(
      pool: 'tank',
      name: 'alice',
      ugid: 1234,
      uid_map: imported_user.uid_map.export,
      gid_map: imported_user.gid_map.export
    )

    allow(OsCtld::DB::Users).to receive(:find).with('alice', pool).and_return(existing_user)
    allow(importer).to receive(:load_user).and_return(
      FakeObjects::FakeUser.new(name: 'alice', userdir: '/userdir', ugid: 9999)
    )

    expect(importer.get_or_create_user).to eq(existing_user)
    expect(OsCtld::UGidRegistry).to have_received(:remove).with(9999)
  end

  it 'rejects mismatched imported user maps' do
    importer.load_metadata
    existing_user = FakeObjects::FakeUser.new(name: 'alice', userdir: '/userdir', ugid: 1234)
    different_user = FakeObjects::FakeUser.new(
      name: 'alice',
      userdir: '/userdir',
      ugid: 9999,
      uid_map: FakeObjects::FakeIdMap.new([FakeObjects::FakeIdMapEntry.new(ns_id: 0, host_id: 300_000, id_count: 65_536)])
    )

    allow(OsCtld::DB::Users).to receive(:find).with('alice', pool).and_return(existing_user)
    allow(importer).to receive(:load_user).and_return(different_user)

    expect { importer.get_or_create_user }.to raise_error(/uid_map mismatch/)
  end

  it 'creates missing groups, returns existing groups, and installs hook scripts' do
    importer.load_metadata
    imported_group = double(name: '/default')
    allow(importer).to receive(:load_group).and_return(imported_group)
    allow(OsCtld::DB::Groups).to receive(:find).with('/default', pool).and_return(nil, :created_group, :existing_group)

    expect(importer.get_or_create_group).to eq(:created_group)
    expect(importer.get_or_create_group).to eq(:existing_group)

    with_tmpdir do |dir|
      ct = double(user_hook_script_dir: File.join(dir, 'hooks'))
      FileUtils.mkdir_p(ct.user_hook_script_dir)
      importer.install_user_hook_scripts(ct)

      expect(File.read(File.join(dir, 'hooks', 'pre-start'))).to include('exit 0')
      expect(File.stat(File.join(dir, 'hooks', 'pre-start')).mode & 0o777).to eq(0o755)
    end
  end

  it 'creates datasets and imports tar root datasets through the builder' do
    importer.load_metadata
    root_ds = double(name: 'tank/ct/ct1')
    ctrc = double(dataset: root_ds, map_mode: 'zfs', rootfs: '/rootfs')
    builder = double(ctrc: ctrc, create_dataset: nil, setup_rootfs: nil)
    dataset_one = double(exist: false, root?: true)
    dataset_two = double(exist: false, root?: false)

    allow(importer).to receive(:datasets).with(builder).and_return([dataset_one, dataset_two])
    allow(importer).to receive(:unpack_rootfs)

    importer.create_datasets(builder, properties: { 'compression' => 'lz4' })
    importer.import_root_dataset(builder)

    expect(builder).to have_received(:create_dataset).with(
      dataset_one,
      mapping: true,
      parents: true,
      properties: { 'compression' => 'lz4' }
    )
    expect(builder).to have_received(:create_dataset).with(
      dataset_two,
      mapping: true,
      parents: false,
      properties: { 'compression' => 'lz4' }
    )
    expect(importer).to have_received(:unpack_rootfs).with(builder)
  end

  it 'closes the tar reader' do
    importer.load_metadata
    tar = importer.send(:tar)
    allow(tar).to receive(:close)

    importer.close

    expect(tar).to have_received(:close)
  end
end
# rubocop:enable RSpec/VerifiedDoubles
