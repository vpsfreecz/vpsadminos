# frozen_string_literal: true

require 'spec_helper'
require 'osctl/exportfs/cli'

RSpec.describe OsCtl::ExportFS::Cli::Export do
  subject(:command) { build_command(described_class, args:, opts:) }

  let(:args) { [] }
  let(:opts) { {} }

  before do
    allow(OsCtl::Lib::Logger).to receive(:setup)
  end

  it 'lists exports for all servers or a single selected server' do
    export = OsCtl::ExportFS::Export.new(dir: '/srv/data', as: '/exports/data', host: '*', options: 'rw')
    cfg = instance_double(OsCtl::ExportFS::Config::TopLevel, exports: [export])
    server_a = instance_double(OsCtl::ExportFS::Server, name: 'alpha', open_config: cfg)
    server_b = instance_double(OsCtl::ExportFS::Server, name: 'beta', open_config: cfg)

    allow(OsCtl::ExportFS::Operations::Server::List).to receive(:run).and_return([server_a, server_b])
    allow(OsCtl::ExportFS::Server).to receive(:new).with('alpha').and_return(server_a)

    all = capture_stdout { build_command(described_class).list }
    one = capture_stdout { build_command(described_class, args: ['alpha']).list }

    expect(all).to include("server  = alpha\n")
    expect(all).to include("server  = beta\n")
    expect(one).to include("server  = alpha\n")
    expect(one).not_to include("server  = beta\n")
  end

  it 'builds an Export object for add and delegates remove' do
    server = instance_double(OsCtl::ExportFS::Server)
    allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(server)
    allow(OsCtl::ExportFS::Operations::Export::Add).to receive(:run)
    allow(OsCtl::ExportFS::Operations::Export::Remove).to receive(:run)

    build_command(
      described_class,
      args: ['srv'],
      opts: { directory: '/srv/data', as: '/exports/data', host: '*', options: 'rw' }
    ).add

    build_command(
      described_class,
      args: ['srv'],
      opts: { as: '/exports/data', host: '*' }
    ).remove

    expect(OsCtl::ExportFS::Operations::Export::Add).to have_received(:run) do |arg_server, export|
      expect(arg_server).to eq(server)
      expect(export).to have_attributes(
        dir: '/srv/data',
        as: '/exports/data',
        host: '*',
        options: 'rw'
      )
    end

    expect(OsCtl::ExportFS::Operations::Export::Remove).to have_received(:run)
      .with(server, '/exports/data', '*')
  end

  it 'validates required arguments strictly' do
    expect { build_command(described_class).add }.to raise_error(GLI::BadCommandLine, 'missing argument <server>')
    expect { build_command(described_class).remove }.to raise_error(GLI::BadCommandLine, 'missing argument <server>')
  end
end
