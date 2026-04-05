# frozen_string_literal: true

require 'spec_helper'
require 'osctl/exportfs/cli'

RSpec.describe OsCtl::ExportFS::Cli::Server do
  subject(:command) { build_command(described_class, args:, opts:) }

  let(:args) { [] }
  let(:opts) { {} }

  before do
    allow(OsCtl::Lib::Logger).to receive(:setup)
  end

  it 'lists available columns with --list' do
    output = capture_stdout { build_command(described_class, opts: { list: true }).list }

    expect(output).to eq("server\nstate\nnetif\naddress\n")
  end

  it 'uses default columns and adds sort columns to the formatter set' do
    cfg = instance_double(OsCtl::ExportFS::Config::TopLevel, netif: 'nfs-srv', address: '192.0.2.60')
    server = instance_double(OsCtl::ExportFS::Server, name: 'srv', running?: true, open_config: cfg)
    allow(OsCtl::ExportFS::Operations::Server::List).to receive(:run).and_return([server])
    allow(OsCtl::Lib::Cli::OutputFormatter).to receive(:print)

    build_command(described_class, opts: { output: 'server', sort: 'address' }).list

    expect(OsCtl::Lib::Cli::OutputFormatter).to have_received(:print).with(
      [{ server: 'srv', state: 'running', netif: 'nfs-srv', address: '192.0.2.60' }],
      layout: :columns,
      cols: %i[server address],
      sort: %i[address]
    )
  end

  it 'delegates create, delete, set, start, stop, restart, spawn, and attach' do
    allow(OsCtl::ExportFS::Operations::Server::Create).to receive(:run)
    allow(OsCtl::ExportFS::Operations::Server::Delete).to receive(:run)
    allow(OsCtl::ExportFS::Operations::Server::Configure).to receive(:run)
    allow(OsCtl::ExportFS::Operations::Server::Spawn).to receive(:run)
    allow(OsCtl::ExportFS::Operations::Server::Attach).to receive(:run)
    allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(:server)

    runsv = instance_double(OsCtl::ExportFS::Operations::Server::Runsv, start: nil, stop: nil, restart: nil)
    allow(OsCtl::ExportFS::Operations::Server::Runsv).to receive(:new).with('srv').and_return(runsv)

    build_command(described_class, args: ['srv'], opts: { 'address' => '192.0.2.60' }).create
    build_command(described_class, args: ['srv']).delete
    build_command(described_class, args: ['srv']).set
    build_command(described_class, args: ['srv']).start
    build_command(described_class, args: ['srv']).stop
    build_command(described_class, args: ['srv']).restart
    build_command(described_class, args: ['srv']).spawn
    build_command(described_class, args: ['srv']).attach

    expect(OsCtl::ExportFS::Operations::Server::Create).to have_received(:run)
      .with('srv', options: hash_including(address: '192.0.2.60'))
    expect(OsCtl::ExportFS::Operations::Server::Delete).to have_received(:run).with('srv')
    expect(OsCtl::ExportFS::Operations::Server::Configure).to have_received(:run).with(:server, anything)
    expect(runsv).to have_received(:start)
    expect(runsv).to have_received(:stop)
    expect(runsv).to have_received(:restart)
    expect(OsCtl::ExportFS::Operations::Server::Spawn).to have_received(:run).with('srv')
    expect(OsCtl::ExportFS::Operations::Server::Attach).to have_received(:run).with('srv')
  end

  it 'parses NFS versions and rejects invalid values' do
    expect(command.send(:parse_nfs_versions, '3,4.1')).to eq(%w[3 4.1])

    expect do
      command.send(:parse_nfs_versions, '5')
    end.to raise_error(
      RuntimeError,
      "invalid NFS version '5', possible values are: 3, 4, 4.0, 4.1, 4.2"
    )
  end
end
