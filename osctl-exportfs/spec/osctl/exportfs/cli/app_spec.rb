# frozen_string_literal: true

require 'spec_helper'
require 'osctl/exportfs/cli'

RSpec.describe OsCtl::ExportFS::Cli::App do
  before do
    allow(OsCtl::Lib::Logger).to receive(:setup)
  end

  it 'builds the CLI app with server and export command trees' do
    app = described_class.new
    app.setup

    expect(app.commands.keys.map(&:to_s)).to include('server', 'export')
    expect(app.commands[:server].commands.keys.map(&:to_s)).to include(
      'ls',
      'new',
      'del',
      'set',
      'start',
      'stop',
      'restart',
      'spawn',
      'attach'
    )
    expect(app.commands[:export].commands.keys.map(&:to_s)).to include('ls', 'add', 'del')
  end

  it 'keeps the create-time nfsd defaults visible on server new switches' do
    app = described_class.new
    app.setup
    command = app.commands[:server].commands[:new]

    expect(command.switches.fetch(:'nfsd-tcp').default_value).to be(true)
    expect(command.switches.fetch(:'nfsd-udp').default_value).to be(false)
    expect(command.switches.fetch(:'nfsd-syslog').default_value).to be(false)
  end

  it 'passes create-time nfsd defaults through server new when switches are omitted' do
    allow(OsCtl::ExportFS::Operations::Server::Create).to receive(:run)

    app = described_class.new
    app.setup
    with_argv(%w[server new --address 10.0.0.10 srv]) do
      expect(app.run(%w[server new --address 10.0.0.10 srv])).to eq(0)
    end
    expect(OsCtl::ExportFS::Operations::Server::Create).to have_received(:run).with(
      'srv',
      options: hash_including(
        nfsd: hash_including(
          tcp: true,
          udp: false,
          syslog: false
        )
      )
    )
  end

  it 'does not pass boolean nfsd defaults through server set unless requested' do
    server = instance_double(OsCtl::ExportFS::Server)
    allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(server)
    allow(OsCtl::ExportFS::Operations::Server::Configure).to receive(:run)

    app = described_class.new
    app.setup
    with_argv(%w[server set srv]) do
      expect(app.run(%w[server set srv])).to eq(0)
    end
    expect(OsCtl::ExportFS::Operations::Server::Configure).to have_received(:run).with(
      server,
      hash_including(
        nfsd: hash_including(
          tcp: nil,
          udp: nil,
          syslog: nil
        )
      )
    )
  end

  it 'passes explicit boolean overrides through server set' do
    server = instance_double(OsCtl::ExportFS::Server)
    allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(server)
    allow(OsCtl::ExportFS::Operations::Server::Configure).to receive(:run)

    app = described_class.new
    app.setup
    with_argv(%w[server set --no-nfsd-tcp --nfsd-udp --nfsd-syslog srv]) do
      expect(app.run(%w[server set --no-nfsd-tcp --nfsd-udp --nfsd-syslog srv])).to eq(0)
    end
    expect(OsCtl::ExportFS::Operations::Server::Configure).to have_received(:run).with(
      server,
      hash_including(
        nfsd: hash_including(
          tcp: false,
          udp: true,
          syslog: true
        )
      )
    )
  end
end
