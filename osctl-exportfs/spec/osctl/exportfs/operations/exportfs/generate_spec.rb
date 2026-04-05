# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Exportfs::Generate do
  it 'generates the exports file from configured exports' do
    with_tmpdir do |tmpdir|
      exports = OsCtl::ExportFS::Config::Exports.new(
        [
          {
            'dir' => '/srv/a',
            'as' => '/exports/a',
            'host' => '*',
            'options' => 'rw'
          },
          {
            'dir' => '/srv/b',
            'as' => '/exports/b',
            'host' => '10.0.0.0/24',
            'options' => 'ro'
          }
        ]
      )
      cfg = instance_double(OsCtl::ExportFS::Config::TopLevel, exports:)
      server = instance_double(
        OsCtl::ExportFS::Server,
        exports_file: File.join(tmpdir, 'exports'),
        open_config: cfg
      )

      described_class.run(server)

      expect(File.read(server.exports_file)).to eq(
        "/exports/a *(rw)\n" \
        "/exports/b 10.0.0.0/24(ro)\n"
      )
    end
  end
end
