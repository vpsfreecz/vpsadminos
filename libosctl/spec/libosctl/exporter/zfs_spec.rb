# frozen_string_literal: true

require 'spec_helper'
require 'zlib'
require 'libosctl/config_file'
require 'libosctl/exceptions'
require 'libosctl/system_command_result'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/exporter/zfs'
require 'libosctl/zfs/dataset'

RSpec.describe OsCtl::Lib::Exporter::Zfs do
  let(:tmpdir) { Dir.mktmpdir('libosctl-spec') }
  let(:root_dataset) { OsCtl::Lib::Zfs::Dataset.new('tank/ct/demo', base: 'tank/ct/demo') }
  let(:data_dataset) { OsCtl::Lib::Zfs::Dataset.new('tank/ct/demo/data', base: 'tank/ct/demo') }
  let(:container) do
    FakeExporterHelpers::FakeContainer.new(
      id: 'demo',
      rootfs: nil,
      user: nil,
      group: nil,
      dataset: root_dataset,
      datasets: [root_dataset, data_dataset],
      config_path: nil
    )
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def gunzip(blob)
    Zlib::GzipReader.wrap(StringIO.new(blob), &:read)
  end

  def stub_zfs(exporter, destroyed:, dataset_compression: 'off')
    allow(exporter).to receive(:zfs) do |cmd, _opts, component|
      case cmd
      when :snapshot
        command_result(exitstatus: 0)
      when :destroy
        destroyed << component
        command_result(exitstatus: 0)
      when :get
        command_result(output: "#{dataset_compression}\n")
      else
        raise "unexpected zfs command #{cmd} for #{component}"
      end
    end
  end

  def dump_base_archive(send_script, compression:, compressed_send:, dataset_compression: 'off')
    archive_io = StringIO.new
    destroyed = []
    exporter = described_class.new(
      container,
      archive_io,
      compression:,
      compressed_send:
    )

    allow(exporter).to receive_messages(snapshot_name: 'base-snap', zfs_send: send_script)
    stub_zfs(exporter, destroyed:, dataset_compression:)

    exporter.dump_rootfs { exporter.dump_base }
    exporter.close

    [tar_entries(archive_io.string), destroyed]
  end

  it 'returns the zfs export format' do
    exporter = described_class.new(container, StringIO.new, compression: :gzip, compressed_send: false)

    expect(exporter.format).to eq(:zfs)
  end

  it 'writes base and incremental streams, records snapshots, and cleans them up in reverse order' do
    send_script = write_executable(tmpdir, 'fake-send', <<~SH)
      printf '%s' "$*"
    SH

    archive_io = StringIO.new
    destroyed = []
    exporter = described_class.new(container, archive_io, compression: :gzip, compressed_send: false)

    allow(exporter).to receive(:snapshot_name).and_return('base-snap', 'incremental-snap')
    allow(exporter).to receive(:zfs_send).and_return(send_script)
    stub_zfs(exporter, destroyed:)

    exporter.dump_rootfs do
      exporter.dump_base
      exporter.dump_incremental
    end
    exporter.close

    entries = tar_entries(archive_io.string)

    expect(entries.fetch('rootfs')).to eq(:directory)
    expect(entries.fetch('rootfs/')).to eq(:directory)
    expect(entries.fetch('rootfs/data')).to eq(:directory)
    expect(entries).to include(
      'rootfs/base.dat.gz',
      'rootfs/data/base.dat.gz',
      'rootfs/incremental.dat.gz',
      'rootfs/data/incremental.dat.gz',
      'snapshots.yml'
    )
    expect(gunzip(entries.fetch('rootfs/base.dat.gz'))).to include('tank/ct/demo@base-snap')
    expect(gunzip(entries.fetch('rootfs/data/base.dat.gz'))).to include('tank/ct/demo/data@base-snap')
    expect(gunzip(entries.fetch('rootfs/incremental.dat.gz'))).to include(
      '-I @base-snap tank/ct/demo@incremental-snap'
    )
    expect(OsCtl::Lib::ConfigFile.load_yaml(entries.fetch('snapshots.yml'))).to eq(
      %w[incremental-snap base-snap]
    )
    expect(destroyed).to eq(
      [
        'tank/ct/demo@incremental-snap',
        'tank/ct/demo@base-snap',
        'tank/ct/demo/data@incremental-snap',
        'tank/ct/demo/data@base-snap'
      ]
    )
  end

  it 'raises when the send subprocess exits non-zero' do
    send_script = write_executable(tmpdir, 'fake-send', <<~SH)
      printf 'stream-data'
      exit 23
    SH

    exporter = described_class.new(container, StringIO.new, compression: :off, compressed_send: false)

    allow(exporter).to receive_messages(snapshot_name: 'base-snap', zfs_send: send_script)
    stub_zfs(exporter, destroyed: [])

    expect do
      exporter.dump_rootfs { exporter.dump_base }
    end.to raise_error(RuntimeError, /zfs send failed with exit status 23/)
  end

  it 'destroys created snapshots even when dumping fails' do
    send_script = write_executable(tmpdir, 'fake-send', <<~SH)
      exit 11
    SH

    destroyed = []
    exporter = described_class.new(container, StringIO.new, compression: :off, compressed_send: false)

    allow(exporter).to receive_messages(snapshot_name: 'base-snap', zfs_send: send_script)
    stub_zfs(exporter, destroyed:)

    expect do
      exporter.dump_rootfs { exporter.dump_base }
    end.to raise_error(RuntimeError, /zfs send failed with exit status 11/)

    expect(destroyed).to eq(
      ['tank/ct/demo@base-snap', 'tank/ct/demo/data@base-snap']
    )
  end

  it 'writes gzipped base streams when compression is forced to gzip' do
    send_script = write_executable(tmpdir, 'fake-send', <<~SH)
      printf 'stream-data'
    SH

    entries, = dump_base_archive(send_script, compression: :gzip, compressed_send: false)

    expect(entries).to include('rootfs/base.dat.gz', 'rootfs/data/base.dat.gz')
    expect(entries).not_to include('rootfs/base.dat', 'rootfs/data/base.dat')
  end

  it 'writes uncompressed base streams when compression is forced off' do
    send_script = write_executable(tmpdir, 'fake-send', <<~SH)
      printf 'stream-data'
    SH

    entries, = dump_base_archive(send_script, compression: :off, compressed_send: false)

    expect(entries).to include('rootfs/base.dat', 'rootfs/data/base.dat')
    expect(entries).not_to include('rootfs/base.dat.gz', 'rootfs/data/base.dat.gz')
  end

  it 'gzips streams in auto mode when compressed sends are disabled' do
    send_script = write_executable(tmpdir, 'fake-send', <<~SH)
      printf 'stream-data'
    SH

    entries, = dump_base_archive(send_script, compression: :auto, compressed_send: false)

    expect(entries).to include('rootfs/base.dat.gz', 'rootfs/data/base.dat.gz')
  end

  it 'gzips streams in auto mode when compressed sends are enabled but dataset compression is off' do
    send_script = write_executable(tmpdir, 'fake-send', <<~SH)
      printf 'stream-data'
    SH

    entries, = dump_base_archive(
      send_script,
      compression: :auto,
      compressed_send: true,
      dataset_compression: 'off'
    )

    expect(entries).to include('rootfs/base.dat.gz', 'rootfs/data/base.dat.gz')
  end

  it 'keeps streams uncompressed in auto mode when dataset compression is enabled' do
    send_script = write_executable(tmpdir, 'fake-send', <<~SH)
      printf 'stream-data'
    SH

    entries, = dump_base_archive(
      send_script,
      compression: :auto,
      compressed_send: true,
      dataset_compression: 'lz4'
    )

    expect(entries).to include('rootfs/base.dat', 'rootfs/data/base.dat')
    expect(entries).not_to include('rootfs/base.dat.gz', 'rootfs/data/base.dat.gz')
  end
end
