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

  it 'reports tar stream import command failures' do
    status = instance_double(Process::Status, success?: false, signaled?: false, exitstatus: 12)
    command = 'tar -xOf /tmp/image.tar rootfs/base.dat.gz | gunzip | zfs recv -F tank/ct'

    allow(Process).to receive(:spawn) do |*args, **opts|
      expect(args[0..1]).to eq(%w[bash -c])
      expect(args[2]).to include(command)
      File.write(args[4], "2 0 0\n")
      opts.fetch(:err).write("tar: truncated archive\n")
      123
    end
    allow(Process).to receive(:wait2).with(123).and_return([123, status])

    expect do
      builder.from_tar_stream('/tmp/image.tar', 'rootfs/base.dat.gz', :gzip, dataset)
    end.to raise_error(
      OsCtld::CommandFailed,
      "failed to import stream: stage 1 'tar -xOf /tmp/image.tar rootfs/base.dat.gz' " \
      'exited with 2; shell exited with 12, stderr: tar: truncated archive'
    )
    expect(Process).to have_received(:spawn).once
    expect(Process).to have_received(:wait2).with(123).once
  end

  it 'reports a failed middle stage even when zfs recv succeeds' do
    status = instance_double(Process::Status, success?: false, signaled?: false, exitstatus: 9)

    allow(Process).to receive(:spawn) do |*args, **_opts|
      File.write(args[4], "0 9 0\n")
      126
    end
    allow(Process).to receive(:wait2).with(126).and_return([126, status])

    expect do
      builder.from_tar_stream('/tmp/image.tar', 'rootfs/base.dat.gz', :gzip, dataset)
    end.to raise_error(
      OsCtld::CommandFailed,
      "failed to import stream: stage 2 'gunzip' exited with 9; shell exited with 9"
    )
    expect(Process).to have_received(:spawn).once
    expect(Process).to have_received(:wait2).with(126).once
  end

  it 'shell-escapes tar stream import command arguments' do
    status = instance_double(Process::Status, success?: true)
    command = 'tar -xOf /tmp/image\\ with\\ spaces.tar rootfs/base\\;name.dat | zfs recv -F tank/ct'

    allow(Process).to receive(:spawn) do |*args, **_opts|
      expect(args[2]).to include(command)
      File.write(args[4], "0 0\n")
      125
    end
    allow(Process).to receive(:wait2).with(125).and_return([125, status])

    expect(
      builder.from_tar_stream('/tmp/image with spaces.tar', 'rootfs/base;name.dat', :off, dataset)
    ).to be_nil
    expect(Process).to have_received(:spawn).once
    expect(Process).to have_received(:wait2).with(125).once
  end

  it 'reports signal-terminated tar stream import commands' do
    status = instance_double(Process::Status, success?: false, signaled?: true, termsig: 15)
    command = 'tar -xOf /tmp/image.tar rootfs/base.dat | zfs recv -F tank/ct'

    allow(Process).to receive(:spawn) do |*args, **_opts|
      expect(args[2]).to include(command)
      124
    end
    allow(Process).to receive(:wait2).with(124).and_return([124, status])

    expect do
      builder.from_tar_stream('/tmp/image.tar', 'rootfs/base.dat', :off, dataset)
    end.to raise_error(
      OsCtld::CommandFailed,
      'failed to import stream: pipeline reported 0 of 2 stage statuses; ' \
      'shell exited with signal 15'
    )
    expect(Process).to have_received(:spawn).once
    expect(Process).to have_received(:wait2).with(124).once
  end
end
# rubocop:enable RSpec/VerifiedDoubles
