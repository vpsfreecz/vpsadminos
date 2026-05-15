# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Export::Remove do
  let(:exports_cfg) { OsCtl::ExportFS::Config::Exports.new([]) }
  let(:cfg) { instance_double(OsCtl::ExportFS::Config::TopLevel, exports: exports_cfg, save: nil) }
  let(:server) { instance_double(OsCtl::ExportFS::Server, open_config: cfg, running?: false) }
  let(:sys) { build_fake_sys }

  before do
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
  end

  it 'is a no-op when the export is absent' do
    expect(described_class.new(server, '/exports/data', '*').execute).to be_nil
    expect(cfg).not_to have_received(:save)
  end

  it 'removes the export from config and saves' do
    export = OsCtl::ExportFS::Export.new(dir: '/srv/data', as: '/exports/data', host: '*', options: 'rw')
    exports_cfg << export

    described_class.new(server, '/exports/data', '*').execute

    expect(exports_cfg.lookup('/exports/data', '*')).to be_nil
    expect(cfg).to have_received(:save)
  end

  it 'unexports a running share and unmounts only the last target' do
    export = OsCtl::ExportFS::Export.new(dir: '/srv/data', as: '/exports/data', host: '*', options: 'rw')
    exports_cfg << export
    allow(server).to receive(:running?).and_return(true)
    allow(server).to receive(:enter_ns)
    allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run) do |_server, &block|
      block.call
    end
    allow(OsCtl::ExportFS::Operations::Exportfs::Generate).to receive(:run)

    op = described_class.new(server, '/exports/data', '*')
    allow(op).to receive(:find_executable!).with('exportfs').and_return('/nix/store/exportfs/bin/exportfs')
    allow(op).to receive(:syscmd_argv)
    op.execute

    expect(OsCtl::ExportFS::Operations::Exportfs::Generate).to have_received(:run).with(server)
    expect(op).to have_received(:syscmd_argv).with(
      ['/nix/store/exportfs/bin/exportfs', '-u', '*:/exports/data']
    )
    expect(sys).to have_received(:unmount).with('/exports/data')
  end

  it 'keeps the mount when another export still uses the same target' do
    first = OsCtl::ExportFS::Export.new(dir: '/srv/data', as: '/exports/data', host: '*', options: 'rw')
    second = OsCtl::ExportFS::Export.new(dir: '/srv/data', as: '/exports/data', host: '10.0.0.0/24', options: 'ro')
    exports_cfg << first
    exports_cfg << second
    allow(server).to receive(:running?).and_return(true)
    allow(server).to receive(:enter_ns)
    allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run) do |_server, &block|
      block.call
    end
    allow(OsCtl::ExportFS::Operations::Exportfs::Generate).to receive(:run)

    op = described_class.new(server, '/exports/data', '*')
    allow(op).to receive(:find_executable!).with('exportfs').and_return('/nix/store/exportfs/bin/exportfs')
    allow(op).to receive(:syscmd_argv)
    op.execute

    expect(sys).not_to have_received(:unmount)
    expect(op).to have_received(:syscmd_argv).with(
      ['/nix/store/exportfs/bin/exportfs', '-u', '*:/exports/data']
    )
  end

  it 'ignores missing active exports reported by exportfs and unmounts the last target' do
    export = OsCtl::ExportFS::Export.new(dir: '/srv/data', as: '/exports/data', host: '*', options: 'rw')
    exports_cfg << export
    allow(server).to receive(:running?).and_return(true)
    allow(server).to receive(:enter_ns)
    allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run) do |_server, &block|
      block.call
    end
    allow(OsCtl::ExportFS::Operations::Exportfs::Generate).to receive(:run)

    op = described_class.new(server, '/exports/data', '*')
    allow(op).to receive(:find_executable!).with('exportfs').and_return('/nix/store/exportfs/bin/exportfs')
    allow(op).to receive(:syscmd_argv).and_raise(
      OsCtl::Lib::Exceptions::SystemCommandFailed.new(
        '/nix/store/exportfs/bin/exportfs -u *:/exports/data',
        1,
        "exportfs: Could not find '*:/exports/data' to unexport.\n"
      )
    )

    expect { op.execute }.not_to raise_error

    expect(exports_cfg.lookup('/exports/data', '*')).to be_nil
    expect(cfg).to have_received(:save)
    expect(OsCtl::ExportFS::Operations::Exportfs::Generate).to have_received(:run).with(server)
    expect(sys).to have_received(:unmount).with('/exports/data')
  end

  it 'raises other exportfs failures and does not unmount the target' do
    export = OsCtl::ExportFS::Export.new(dir: '/srv/data', as: '/exports/data', host: '*', options: 'rw')
    exports_cfg << export
    allow(server).to receive(:running?).and_return(true)
    allow(server).to receive(:enter_ns)
    allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run) do |_server, &block|
      block.call
    end
    allow(OsCtl::ExportFS::Operations::Exportfs::Generate).to receive(:run)

    error = OsCtl::Lib::Exceptions::SystemCommandFailed.new(
      '/nix/store/exportfs/bin/exportfs -u *:/exports/data',
      1,
      "exportfs: failed to write /var/lib/nfs/etab\n"
    )
    op = described_class.new(server, '/exports/data', '*')
    allow(op).to receive(:find_executable!).with('exportfs').and_return('/nix/store/exportfs/bin/exportfs')
    allow(op).to receive(:syscmd_argv).and_raise(error)

    expect { op.execute }.to raise_error(error)
    expect(sys).not_to have_received(:unmount)
  end

  it 'runs exportfs from the caller path when removing a running export' do
    export = OsCtl::ExportFS::Export.new(dir: '/srv/data', as: '/exports/data', host: '*', options: 'rw')
    exports_cfg << export
    allow(server).to receive(:running?).and_return(true)
    allow(server).to receive(:enter_ns)
    allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run) do |_server, &block|
      block.call
    end
    allow(OsCtl::ExportFS::Operations::Exportfs::Generate).to receive(:run)

    with_fake_path_command('exportfs') do |path, marker|
      op = described_class.new(server, '/exports/data', '*')
      allow(op).to receive(:log)
      op.execute

      expect(path).to include('/nix/store/')
      expect(File.read(marker)).to include(
        "#{File.join(path, 'exportfs')} -u *:/exports/data"
      )
    end

    expect(exports_cfg.lookup('/exports/data', '*')).to be_nil
    expect(sys).to have_received(:unmount).with('/exports/data')
  end
end
