# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/system_command_result'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/zfs/snapshot'
require 'libosctl/zfs/dataset'

RSpec.describe OsCtl::Lib::Zfs::Dataset do
  let(:dataset) { described_class.new('tank/ct/test/root', base: 'tank/ct/test', properties:) }

  let(:properties) { { 'mountpoint' => '/tank/ct/test/root' } }

  it 'exposes basic dataset helpers' do
    expect(dataset.name).to eq('tank/ct/test/root')
    expect(dataset.pool).to eq('tank')
    expect(dataset.base).to eq('tank/ct/test')
    expect(dataset.to_s).to eq('tank/ct/test/root')
    expect(dataset).to be_on_pool('tank')
    expect(dataset).not_to be_on_pool('fast')
    expect(dataset).not_to be_is_pool
    expect(dataset).to be_subdataset_of(described_class.new('tank/ct/test', base: 'tank/ct/test'))
    expect(described_class.new('tank', base: 'tank')).to be_is_pool
  end

  it 'builds create, destroy, and exist zfs commands' do
    allow(dataset).to receive(:zfs).and_return(command_result(exitstatus: 0))

    dataset.create!(parents: true, properties: { compression: 'lz4', quota: '10G' })
    expect(dataset).to have_received(:zfs).with(
      :create,
      '-p -o compression=lz4 -o quota=10G',
      'tank/ct/test/root'
    )

    dataset.destroy!(recursive: true)
    expect(dataset).to have_received(:zfs).with(:destroy, '-r', 'tank/ct/test/root')

    allow(dataset).to receive(:zfs).with(
      :get,
      '-o value name',
      'tank/ct/test/root',
      valid_rcs: [1]
    ).and_return(command_result(exitstatus: 0))
    expect(dataset.exist?).to be(true)
    expect(dataset).to have_received(:zfs).with(
      :get,
      '-o value name',
      'tank/ct/test/root',
      valid_rcs: [1]
    )
  end

  it 'creates the private directory below the mountpoint' do
    with_tmpdir do |dir|
      ds = described_class.new('tank/ct/test/root', base: 'tank/ct/test', properties: { 'mountpoint' => dir })

      ds.create_private!

      expect(ds.private_path).to eq(File.join(dir, 'private'))
      expect(Dir).to exist(ds.private_path)
    end
  end

  it 'parses listed datasets and properties from zfs get output' do
    allow(dataset).to receive(:zfs).and_return(command_result(output: <<~OUT))
      tank/ct/test/root name tank/ct/test/root
      tank/ct/test/root mountpoint /tank/ct/test/root
      tank/ct/test/root quota 10G
      tank/ct/test/root/sub name tank/ct/test/root/sub
      tank/ct/test/root/sub mountpoint /tank/ct/test/root/sub
    OUT

    listed = dataset.list(properties: %i[mountpoint quota])

    expect(listed.map(&:name)).to eq(['tank/ct/test/root', 'tank/ct/test/root/sub'])
    expect(listed.first.properties).to include('mountpoint' => '/tank/ct/test/root', 'quota' => '10G')
    expect(listed.last.properties).to include('mountpoint' => '/tank/ct/test/root/sub')
  end

  it 'caches the mountpoint when it has to read it from zfs' do
    ds = described_class.new('tank/ct/test/root', base: 'tank/ct/test')

    allow(ds).to receive(:zfs).with(:get, '-H -o value mountpoint', 'tank/ct/test/root').and_return(
      command_result(output: "/mnt/root\n")
    )

    expect(ds.mountpoint).to eq('/mnt/root')
    expect(ds.mountpoint).to eq('/mnt/root')
    expect(ds).to have_received(:zfs).with(:get, '-H -o value mountpoint', 'tank/ct/test/root').once
  end

  it 'mounts, unmounts, and checks mounted state' do
    allow(dataset).to receive(:zfs).and_return(command_result(output: ''))
    allow(dataset).to receive(:zfs).with(
      :list,
      '-H -o name,mounted -t filesystem ',
      'tank/ct/test/root'
    ).and_return(command_result(output: "tank/ct/test/root no\ntank/ct/test/root/sub yes\n"))

    dataset.mount
    expect(dataset).to have_received(:zfs).with(:mount, nil, 'tank/ct/test/root')

    allow(dataset).to receive(:zfs).with(
      :list,
      '-H -o name,mounted -t filesystem -r',
      'tank/ct/test/root'
    ).and_return(command_result(output: "tank/ct/test/root/sub yes\ntank/ct/test/root yes\n"))

    dataset.unmount(recursive: true)
    expect(dataset).to have_received(:zfs).with(:unmount, nil, 'tank/ct/test/root')
    expect(dataset).to have_received(:zfs).with(:unmount, nil, 'tank/ct/test/root/sub')

    allow(dataset).to receive(:zfs).with(
      :get,
      '-H -r -t filesystem -o value mounted',
      'tank/ct/test/root'
    ).and_return(command_result(output: "yes\nyes\n"))

    expect(dataset.mounted?(recursive: true)).to be(true)
  end

  it 'ignores concurrent ZFS mount and unmount state changes' do
    allow(dataset).to receive(:zfs).and_return(command_result(output: ''))
    allow(dataset).to receive(:zfs).with(
      :list,
      '-H -o name,mounted -t filesystem ',
      'tank/ct/test/root'
    ).and_return(command_result(output: "tank/ct/test/root no\n"))
    allow(dataset).to receive(:zfs).with(:mount, nil, 'tank/ct/test/root')
                                   .and_raise(OsCtl::Lib::Exceptions::SystemCommandFailed.new(
                                                'zfs mount',
                                                1,
                                                "cannot mount 'tank/ct/test/root': filesystem already mounted"
                                              ))

    expect { dataset.mount }.not_to raise_error

    allow(dataset).to receive(:zfs).with(
      :list,
      '-H -o name,mounted -t filesystem -r',
      'tank/ct/test/root'
    ).and_return(command_result(output: "tank/ct/test/root yes\n"))
    allow(dataset).to receive(:zfs).with(:unmount, nil, 'tank/ct/test/root')
                                   .and_raise(OsCtl::Lib::Exceptions::SystemCommandFailed.new(
                                                'zfs unmount',
                                                1,
                                                "cannot unmount 'tank/ct/test/root': not currently mounted"
                                              ))

    expect { dataset.unmount(recursive: true) }.not_to raise_error
  end

  it 'derives parent relationships and relative dataset names' do
    expect(dataset.parent.name).to eq('tank/ct/test')
    expect(dataset.parents.map(&:name)).to eq(%w[tank/ct/test tank/ct tank])
    expect(dataset.base_name).to eq('root')
    expect(dataset.relative_name).to eq('root')
    expect(dataset.relative_parent.name).to eq('tank/ct/test')
    expect(dataset.relative_parents.map(&:name)).to eq(['tank/ct/test'])
    expect(dataset).not_to be_root
    expect(described_class.new('tank/ct/test', base: 'tank/ct/test')).to be_root
    expect(described_class.new('tank', base: 'tank')).to be_root
  end

  it 'returns nil for relative_parent on a root/base dataset' do
    expect(described_class.new('tank', base: 'tank').relative_parent).to be_nil
  end

  it 'derives children and descendants from the list helper' do
    child = described_class.new('tank/ct/test/root/child', base: 'tank/ct/test')
    grandchild = described_class.new('tank/ct/test/root/child/grand', base: 'tank/ct/test')

    allow(dataset).to receive(:list).with(depth: 1).and_return([dataset, child])
    allow(dataset).to receive(:list).with(no_args).and_return([dataset, child, grandchild])

    expect(dataset.children.map(&:name)).to eq(['tank/ct/test/root/child'])
    expect(dataset.descendants.map(&:name)).to eq(
      ['tank/ct/test/root/child', 'tank/ct/test/root/child/grand']
    )
  end

  it 'lists snapshots and exports datasets for clients' do
    allow(dataset).to receive(:zfs).with(
      :get,
      '-r -H -p -o name,property,value -t snapshot -d 1 name',
      'tank/ct/test/root'
    ).and_return(command_result(output: <<~OUT))
      tank/ct/test/root@a name tank/ct/test/root@a
      tank/ct/test/root@b name tank/ct/test/root@b
    OUT

    snapshots = dataset.snapshots

    expect(snapshots.map(&:snapshot)).to eq(%w[a b])
    expect(dataset.export).to include(
      'name' => 'root',
      'dataset' => 'tank/ct/test/root',
      'mountpoint' => '/tank/ct/test/root'
    )
  end
end
