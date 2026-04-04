# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/exceptions'
require 'libosctl/system_command_result'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/exporter/tar'

RSpec.describe OsCtl::Lib::Exporter::Tar do
  let(:archive_io) { StringIO.new }

  it 'returns the tar export format' do
    container = FakeExporterHelpers::FakeContainer.new(
      id: 'demo',
      rootfs: '/tmp',
      user: nil,
      group: nil,
      dataset: nil,
      datasets: [],
      config_path: nil
    )

    expect(described_class.new(container, archive_io).format).to eq(:tar)
  end

  it 'packs the rootfs into rootfs/base.tar.gz' do
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'etc'))
      File.write(File.join(dir, 'etc', 'issue'), "hello\n")

      container = FakeExporterHelpers::FakeContainer.new(
        id: 'demo',
        rootfs: dir,
        user: nil,
        group: nil,
        dataset: nil,
        datasets: [],
        config_path: nil
      )

      exporter = described_class.new(container, archive_io)
      exporter.pack_rootfs
      exporter.close

      outer = tar_entries(archive_io.string)
      inner = gzipped_tar_entries(outer.fetch('rootfs/base.tar.gz'))

      expect(outer.fetch('rootfs')).to eq(:directory)
      expect(inner.keys.grep(%r{(^|/)etc/issue$})).not_to be_empty
      expect(inner.values.grep(/hello/)).not_to be_empty
    end
  end

  it 'raises when the tar subprocess fails' do
    with_tmpdir do |dir|
      container = FakeExporterHelpers::FakeContainer.new(
        id: 'demo',
        rootfs: File.join(dir, 'missing'),
        user: nil,
        group: nil,
        dataset: nil,
        datasets: [],
        config_path: nil
      )

      exporter = described_class.new(container, archive_io)

      expect { exporter.pack_rootfs }.to raise_error(RuntimeError, /tar failed with exit status/)
    end
  end
end
