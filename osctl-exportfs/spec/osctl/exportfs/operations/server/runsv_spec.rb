# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Server::Runsv do
  let(:server) do
    instance_double(
      OsCtl::ExportFS::Server,
      name: 'srv',
      runsv_dir: '/servers/srv/runsv'
    )
  end
  let(:cfg) { instance_double(OsCtl::ExportFS::Config::TopLevel, address: '192.0.2.40', netif: 'nfs-srv') }

  before do
    allow(server).to receive(:synchronize).and_yield
    allow(server).to receive_messages(open_config: cfg, running?: false)
    allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(server)
  end

  it 'refuses to start an already started service' do
    allow(File).to receive(:lstat).and_call_original
    allow(File).to receive(:lstat).with('/run/osctl/exportfs/runsvdir/srv')
                                  .and_return(instance_double(File::Stat))

    expect { described_class.new('srv').start }.to raise_error(RuntimeError, 'server is already running')
  end

  it 'refuses to start when the server address is missing' do
    allow(File).to receive(:lstat).and_call_original
    allow(File).to receive(:lstat).with('/run/osctl/exportfs/runsvdir/srv')
                                  .and_raise(Errno::ENOENT)
    allow(cfg).to receive(:address).and_return(nil)

    expect { described_class.new('srv').start }.to raise_error(RuntimeError, 'provide server address')
  end

  it 'renders the run script and creates the service link' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      allow(File).to receive(:lstat).and_call_original
      allow(File).to receive(:lstat).with(File.join(OsCtl::ExportFS::RunState::RUNSVDIR, 'srv'))
                                    .and_raise(Errno::ENOENT)
      allow(FileUtils).to receive(:mkdir_p)
      allow(OsCtl::ExportFS::ErbTemplate).to receive(:render_to)
      allow(File).to receive(:chmod)
      allow(File).to receive(:symlink)

      described_class.new('srv').start

      expect(FileUtils).to have_received(:mkdir_p).with('/servers/srv/runsv')
      expect(OsCtl::ExportFS::ErbTemplate).to have_received(:render_to).with(
        'runsv',
        { name: 'srv', address: '192.0.2.40', netif: 'nfs-srv' },
        '/servers/srv/runsv/run'
      )
      expect(File).to have_received(:chmod).with(0o755, '/servers/srv/runsv/run')
      expect(File).to have_received(:symlink).with(
        '/servers/srv/runsv',
        File.join(OsCtl::ExportFS::RunState::RUNSVDIR, 'srv')
      )
    end
  end

  it 'removes the service link and waits until the server stops' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      allow(File).to receive(:symlink?).and_return(true)
      allow(File).to receive(:unlink)
      allow(server).to receive(:running?).and_return(true, true, false)

      op = described_class.new('srv')
      allow(op).to receive(:sleep)
      op.stop

      expect(File).to have_received(:unlink).with(File.join(OsCtl::ExportFS::RunState::RUNSVDIR, 'srv'))
      expect(op).to have_received(:sleep).with(1).twice
    end
  end

  it 'restarts in stop-sleep-start order' do
    op = described_class.new('srv')
    allow(op).to receive(:stop)
    allow(op).to receive(:start)
    allow(op).to receive(:sleep)

    op.restart

    expect(op).to have_received(:stop).ordered
    expect(op).to have_received(:sleep).with(1).ordered
    expect(op).to have_received(:start).ordered
  end
end
