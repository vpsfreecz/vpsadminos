# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles

require 'tempfile'

require 'osctld/utils/switch_user'
require 'osctld/container/dataset_builder'

RSpec.describe OsCtld::Container::DatasetBuilder do
  let(:builder) { described_class.new }
  let(:dataset) { double(mountpoint: '/tmp/test-dataset', to_s: 'tank/ct') }
  let(:uid_map) { FakeObjects::FakeIdMap.new([FakeObjects::FakeIdMapEntry.new(ns_id: 0, host_id: 100_000, id_count: 65_536)]) }
  let(:gid_map) { FakeObjects::FakeIdMap.new([FakeObjects::FakeIdMapEntry.new(ns_id: 0, host_id: 200_000, id_count: 65_536)]) }

  before do
    allow(builder).to receive(:zfs)
    allow(builder).to receive(:sleep)
  end

  it 'accepts uid-only mappings when the uid matches' do
    allow(Tempfile).to receive(:create).and_return(instance_double(Tempfile, path: '/tmp/f', close: nil))
    allow(File).to receive(:stat).with('/tmp/f').and_return(instance_double(File::Stat, uid: 100_000, gid: 0))
    allow(File).to receive(:unlink).with('/tmp/f')

    expect do
      builder.shift_dataset(dataset, uid_map: uid_map)
    end.not_to raise_error
  end

  it 'accepts gid-only mappings when the gid matches' do
    allow(Tempfile).to receive(:create).and_return(instance_double(Tempfile, path: '/tmp/f', close: nil))
    allow(File).to receive(:stat).with('/tmp/f').and_return(instance_double(File::Stat, uid: 0, gid: 200_000))
    allow(File).to receive(:unlink).with('/tmp/f')

    expect do
      builder.shift_dataset(dataset, gid_map: gid_map)
    end.not_to raise_error
  end

  it 'requires both uid and gid mappings to take effect when both are provided' do
    tempfiles = Array.new(5) { instance_double(Tempfile, path: '/tmp/f', close: nil) }
    allow(Tempfile).to receive(:create).and_return(*tempfiles)
    allow(File).to receive(:stat).with('/tmp/f').and_return(instance_double(File::Stat, uid: 100_000, gid: 0))
    allow(File).to receive(:unlink).with('/tmp/f')

    expect do
      builder.shift_dataset(dataset, uid_map: uid_map, gid_map: gid_map)
    end.to raise_error(RuntimeError, 'unable to configure UID/GID mapping')
  end

  it 'raises for unexpected compression types in tar streams' do
    expect do
      builder.from_tar_stream('/tmp/image.tar', 'rootfs/base', :xz, dataset)
    end.to raise_error(RuntimeError, "unexpected compression type 'xz'")
  end
end
# rubocop:enable RSpec/VerifiedDoubles
