# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Server::Create do
  it 'refuses to create an existing server' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      server = OsCtl::ExportFS::Server.new('srv')
      FileUtils.mkdir_p(server.dir)

      allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(server)

      expect { described_class.run('srv') }.to raise_error(RuntimeError, 'server already exists')
    end
  end

  it 'creates the server root, state, shared mount, config, and exports file' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      server = OsCtl::ExportFS::Server.new('srv')
      allow(server).to receive(:synchronize).and_yield
      allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(server)

      sys = build_fake_sys
      allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
      allow(OsCtl::ExportFS::Operations::Server::Configure).to receive(:run)

      described_class.run('srv', options: { address: '192.0.2.30' })

      expect(Dir.exist?(server.dir)).to be(true)
      expect(Dir.exist?(server.nfs_state)).to be(true)
      expect(Dir.exist?(server.shared_dir)).to be(true)
      expect(File.read(server.exports_file)).to eq('')
      expect(sys).to have_received(:bind_mount).with(server.shared_dir, server.shared_dir)
      expect(sys).to have_received(:make_shared).with(server.shared_dir)
      expect(OsCtl::ExportFS::Operations::Server::Configure).to have_received(:run)
        .with(server, address: '192.0.2.30')
    end
  end
end
