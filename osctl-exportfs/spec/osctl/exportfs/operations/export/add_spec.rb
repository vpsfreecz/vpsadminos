# frozen_string_literal: true

require 'digest'
require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Export::Add do
  let(:exports_cfg) { OsCtl::ExportFS::Config::Exports.new([]) }
  let(:cfg) { instance_double(OsCtl::ExportFS::Config::TopLevel, exports: exports_cfg, save: nil) }
  let(:server) do
    instance_double(
      OsCtl::ExportFS::Server,
      open_config: cfg,
      running?: false,
      shared_dir: '/servers/srv/shared'
    )
  end
  let(:sys) { build_fake_sys }

  before do
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
    allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run)
  end

  it 'fails when the source directory does not exist' do
    export = OsCtl::ExportFS::Export.new(dir: '/nope', as: '/exports/data', host: '*', options: 'rw')

    expect { described_class.new(server, export).execute }.to raise_error(RuntimeError, 'dir /nope not found')
  end

  it 'rejects conflicting targets and duplicate exports' do
    with_tmpdir do |tmpdir|
      existing = OsCtl::ExportFS::Export.new(
        dir: File.join(tmpdir, 'src-a'),
        as: '/exports/data',
        host: '*',
        options: 'rw'
      )
      exports_cfg << existing
      FileUtils.mkdir_p(existing.dir)

      conflict = OsCtl::ExportFS::Export.new(
        dir: File.join(tmpdir, 'src-b'),
        as: '/exports/data',
        host: '10.0.0.0/24',
        options: 'rw'
      )
      FileUtils.mkdir_p(conflict.dir)

      expect { described_class.new(server, conflict).execute }.to raise_error(
        RuntimeError,
        "source directory mismatch: expected '#{existing.dir}', got '#{conflict.dir}'"
      )

      duplicate = OsCtl::ExportFS::Export.new(
        dir: existing.dir,
        as: '/exports/data',
        host: '*',
        options: 'rw'
      )
      expect { described_class.new(server, duplicate).execute }.to raise_error(
        RuntimeError,
        'export of /exports/data to * already exists'
      )
    end
  end

  it 'appends to the config and saves when the server is stopped' do
    with_tmpdir do |tmpdir|
      export = OsCtl::ExportFS::Export.new(
        dir: File.join(tmpdir, 'src'),
        as: '/exports/data',
        host: '*',
        options: 'rw'
      )
      FileUtils.mkdir_p(export.dir)

      described_class.new(server, export).execute

      expect(exports_cfg.lookup('/exports/data', '*')).to eq(export)
      expect(cfg).to have_received(:save)
      expect(OsCtl::ExportFS::Operations::Server::Exec).not_to have_received(:run)
    end
  end

  it 'propagates and exports a running server share when needed' do
    with_tmpdir do |tmpdir|
      shared_dir = File.join(tmpdir, 'shared')
      export = OsCtl::ExportFS::Export.new(
        dir: File.join(tmpdir, 'src'),
        as: File.join(tmpdir, 'exports', 'data'),
        host: '*',
        options: 'rw'
      )
      FileUtils.mkdir_p(export.dir)
      allow(server).to receive_messages(shared_dir:, running?: true)
      FileUtils.mkdir_p(shared_dir)
      allow(server).to receive(:enter_ns)
      allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run) do |_server, &block|
        block.call
      end
      allow(OsCtl::ExportFS::Operations::Exportfs::Generate).to receive(:run)

      op = described_class.new(server, export)
      allow(op).to receive(:find_executable!).with('exportfs').and_return('/nix/store/exportfs/bin/exportfs')
      allow(op).to receive(:syscmd_argv)
      op.execute

      shared = File.join(shared_dir, Digest::SHA2.hexdigest(export.dir))
      expect(sys).to have_received(:bind_mount).with(export.dir, shared)
      expect(sys).to have_received(:move_mount).with(
        File.join(OsCtl::ExportFS::RunState::CURRENT_SERVER, 'shared', Digest::SHA2.hexdigest(export.dir)),
        export.as
      )
      expect(OsCtl::ExportFS::Operations::Exportfs::Generate).to have_received(:run).with(server)
      expect(op).to have_received(:syscmd_argv).with(
        ['/nix/store/exportfs/bin/exportfs', '-i', '-o', 'rw', "*:#{export.as}"]
      )
      expect(sys).to have_received(:unmount).with(shared)
      expect(Dir.exist?(shared)).to be(false)
    end
  end

  it 'skips propagation when the target is already mounted' do
    with_tmpdir do |tmpdir|
      original = OsCtl::ExportFS::Export.new(
        dir: File.join(tmpdir, 'src'),
        as: '/exports/data',
        host: '*',
        options: 'rw'
      )
      FileUtils.mkdir_p(original.dir)
      exports_cfg << original
      allow(server).to receive(:running?).and_return(true)
      allow(server).to receive(:enter_ns)
      allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run) { |_server, &block| block.call }
      allow(OsCtl::ExportFS::Operations::Exportfs::Generate).to receive(:run)

      added = OsCtl::ExportFS::Export.new(
        dir: original.dir,
        as: '/exports/data',
        host: '10.0.0.0/24',
        options: 'rw'
      )
      op = described_class.new(server, added)
      allow(op).to receive(:find_executable!).with('exportfs').and_return('/nix/store/exportfs/bin/exportfs')
      allow(op).to receive(:syscmd_argv)
      op.execute

      expect(sys).not_to have_received(:bind_mount)
      expect(sys).not_to have_received(:move_mount)
      expect(OsCtl::ExportFS::Operations::Exportfs::Generate).not_to have_received(:run)
      expect(op).to have_received(:syscmd_argv).with(
        ['/nix/store/exportfs/bin/exportfs', '-i', '-o', 'rw', '10.0.0.0/24:/exports/data']
      )
    end
  end

  it 'runs exportfs from the caller path for already mounted targets' do
    with_tmpdir do |tmpdir|
      original = OsCtl::ExportFS::Export.new(
        dir: File.join(tmpdir, 'src'),
        as: '/exports/data',
        host: '*',
        options: 'rw'
      )
      FileUtils.mkdir_p(original.dir)
      exports_cfg << original
      allow(server).to receive(:running?).and_return(true)
      allow(server).to receive(:enter_ns)
      allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run) { |_server, &block| block.call }

      added = OsCtl::ExportFS::Export.new(
        dir: original.dir,
        as: '/exports/data',
        host: '10.0.0.0/24',
        options: 'rw'
      )

      with_fake_path_command('exportfs') do |path, marker|
        op = described_class.new(server, added)
        allow(op).to receive(:log)
        op.execute

        expect(path).to include('/nix/store/')
        expect(File.read(marker)).to include(
          "#{File.join(path, 'exportfs')} -i -o rw 10.0.0.0/24:/exports/data"
        )
      end

      expect(exports_cfg.lookup('/exports/data', '10.0.0.0/24')).to eq(added)
    end
  end

  it 'cleans up temporary propagation mounts when namespace execution fails' do
    with_tmpdir do |tmpdir|
      shared_dir = File.join(tmpdir, 'shared')
      export = OsCtl::ExportFS::Export.new(
        dir: File.join(tmpdir, 'src'),
        as: '/exports/data',
        host: '*',
        options: 'rw'
      )
      FileUtils.mkdir_p(export.dir)
      allow(server).to receive_messages(shared_dir:, running?: true)
      FileUtils.mkdir_p(shared_dir)
      allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run)
        .and_raise(RuntimeError, 'server exec failed with exit status 7')

      op = described_class.new(server, export)
      allow(op).to receive(:find_executable!).with('exportfs').and_return('/nix/store/exportfs/bin/exportfs')

      expect do
        op.execute
      end.to raise_error(RuntimeError, 'server exec failed with exit status 7')

      shared = File.join(shared_dir, Digest::SHA2.hexdigest(export.dir))
      expect(sys).to have_received(:unmount).with(shared)
      expect(Dir.exist?(shared)).to be(false)
    end
  end
end
