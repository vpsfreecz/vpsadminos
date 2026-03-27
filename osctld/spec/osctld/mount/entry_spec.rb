# frozen_string_literal: true

require 'libosctl'
require 'osctld/mount/entry'

RSpec.describe OsCtld::Mount::Entry do
  def build_ct(root)
    dataset = OsCtl::Lib::Zfs::Dataset.new(
      'tank/ct/ct1',
      base: 'tank/ct/ct1',
      properties: { 'mountpoint' => root }
    )

    Struct.new(:dataset).new(dataset)
  end

  it 'loads plain filesystem mounts from config' do
    entry = described_class.load(
      build_ct('/pool/ct1'),
      'fs' => '/src',
      'mountpoint' => '/dst',
      'type' => 'bind',
      'opts' => 'bind',
      'automount' => true,
      'map_ids' => false,
      'temporary' => true
    )

    expect(entry.fs).to eq('/src')
    expect(entry.lxc_mountpoint).to eq('dst')
    expect(entry.export).to eq(
      fs: '/src',
      mountpoint: '/dst',
      type: 'bind',
      opts: 'bind',
      automount: true,
      dataset: nil,
      map_ids: false,
      temporary: true
    )
  end

  it 'loads dataset-relative mounts and dumps relative dataset names' do
    entry = described_class.load(
      build_ct('/pool/ct1'),
      'fs' => nil,
      'mountpoint' => '/data',
      'type' => 'none',
      'opts' => 'bind,ro',
      'automount' => true,
      'dataset' => 'subdir'
    )
    allow(entry.dataset).to receive(:mountpoint).and_return('/pool/ct1/private/subdir')

    expect(entry.fs).to eq('/pool/ct1/private/subdir/private')
    expect(entry.dump).to eq(
      'fs' => nil,
      'mountpoint' => '/data',
      'type' => 'none',
      'opts' => 'bind,ro',
      'automount' => true,
      'dataset' => 'subdir',
      'map_ids' => true,
      'temporary' => nil
    )
  end

  it 'rebinds dataset-backed mounts when duplicated for another container' do
    entry = described_class.load(
      build_ct('/pool/ct1'),
      'fs' => nil,
      'mountpoint' => '/data',
      'type' => 'none',
      'opts' => 'bind',
      'automount' => true,
      'dataset' => 'subdir'
    )
    allow(entry.dataset).to receive(:mountpoint).and_return('/pool/ct1/private/subdir')

    new_ct = Struct.new(:dataset).new(
      OsCtl::Lib::Zfs::Dataset.new(
        'tank/ct/ct2',
        base: 'tank/ct/ct2',
        properties: { 'mountpoint' => '/pool/ct2' }
      )
    )

    copy = entry.dup(new_ct)
    allow(copy.dataset).to receive(:mountpoint).and_return('/pool/ct2/private/subdir')

    expect(copy.fs).to eq('/pool/ct2/private/subdir/private')
    expect(copy.export[:dataset]).to eq('subdir')
  end
end
