# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Config::TopLevel do
  def build_server(path, name: 'srv')
    instance_double(OsCtl::ExportFS::Server, name:, config_file: path).tap do |server|
      allow(server).to receive(:synchronize).and_yield
    end
  end

  it 'uses defaults when no config file exists' do
    with_tmpdir do |tmpdir|
      cfg = described_class.new(build_server(File.join(tmpdir, 'config.yml')))

      expect(cfg.address).to be_nil
      expect(cfg.netif).to eq('nfs-srv')
      expect(cfg.exports.dump).to eq([])
      expect(cfg.nfsd.dump).to eq(
        'port' => nil,
        'nproc' => 8,
        'tcp' => true,
        'udp' => false,
        'versions' => %w[3 4 4.0 4.1 4.2],
        'syslog' => false
      )
    end
  end

  it 'reads an existing config file and defaults netif from the server name' do
    with_tmpdir do |tmpdir|
      path = File.join(tmpdir, 'config.yml')
      File.write(
        path,
        OsCtl::Lib::ConfigFile.dump_yaml(
          'address' => '192.0.2.10',
          'nfsd' => { 'tcp' => false, 'versions' => %w[4.1] },
          'exports' => [
            {
              'dir' => '/srv/data',
              'as' => '/exports/data',
              'host' => '*',
              'options' => 'rw'
            }
          ]
        )
      )

      cfg = described_class.new(build_server(path))

      expect(cfg.address).to eq('192.0.2.10')
      expect(cfg.netif).to eq('nfs-srv')
      expect(cfg.nfsd.tcp).to be(false)
      expect(cfg.nfsd.versions).to eq(%w[4.1])
      expect(cfg.exports.lookup('/exports/data', '*')).not_to be_nil
    end
  end

  it 'omits the default netif in the dumped config and round-trips through save' do
    with_tmpdir do |tmpdir|
      path = File.join(tmpdir, 'config.yml')
      server = build_server(path)

      cfg = described_class.new(server)
      cfg.address = '192.0.2.11'
      cfg.netif = 'nfs-srv'
      cfg.mountd_port = 20_048
      cfg.exports << OsCtl::ExportFS::Export.new(
        dir: '/srv/data',
        as: '/exports/data',
        host: '*',
        options: 'rw'
      )

      cfg.save

      raw = OsCtl::Lib::ConfigFile.load_yaml_file(path)
      expect(raw['netif']).to be_nil

      reloaded = described_class.new(server)
      expect(reloaded.address).to eq('192.0.2.11')
      expect(reloaded.netif).to eq('nfs-srv')
      expect(reloaded.mountd_port).to eq(20_048)
      expect(reloaded.exports.lookup('/exports/data', '*')).not_to be_nil
    end
  end

  it 'wraps read and save access in server synchronization' do
    with_tmpdir do |tmpdir|
      path = File.join(tmpdir, 'config.yml')
      File.write(path, OsCtl::Lib::ConfigFile.dump_yaml({}))

      server = instance_spy(OsCtl::ExportFS::Server, name: 'srv', config_file: path)
      allow(server).to receive(:synchronize).and_yield

      cfg = described_class.new(server)
      cfg.save

      expect(server).to have_received(:synchronize).twice
    end
  end
end
