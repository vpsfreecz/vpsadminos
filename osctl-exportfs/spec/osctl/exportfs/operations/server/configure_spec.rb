# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Server::Configure do
  it 'sets top-level options and persists them' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      server = OsCtl::ExportFS::Server.new('srv')
      FileUtils.mkdir_p(server.dir)
      allow(server).to receive(:synchronize).and_yield

      described_class.run(server, address: '192.0.2.20', netif: 'nfs-custom', mountd_port: 20_048)

      cfg = server.open_config
      expect(cfg.address).to eq('192.0.2.20')
      expect(cfg.netif).to eq('nfs-custom')
      expect(cfg.mountd_port).to eq(20_048)
    end
  end

  it 'updates only selected nfsd settings and leaves others intact' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      server = OsCtl::ExportFS::Server.new('srv')
      FileUtils.mkdir_p(server.dir)
      allow(server).to receive(:synchronize).and_yield

      described_class.run(
        server,
        nfsd: {
          port: 2049,
          nproc: 8,
          tcp: false,
          udp: true,
          versions: %w[4.1],
          syslog: true
        }
      )

      described_class.run(server, nfsd: { nproc: 16 })
      cfg = server.open_config

      expect(cfg.nfsd.port).to eq(2049)
      expect(cfg.nfsd.nproc).to eq(16)
      expect(cfg.nfsd.tcp).to be(false)
      expect(cfg.nfsd.udp).to be(true)
      expect(cfg.nfsd.versions).to eq(%w[4.1])
      expect(cfg.nfsd.syslog).to be(true)
    end
  end
end
