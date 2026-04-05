# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Runit::Generate do
  let(:server) { instance_double(OsCtl::ExportFS::Server, name: 'srv') }
  let(:config) { instance_double(OsCtl::ExportFS::Config::TopLevel) }

  it 'renders runit scripts, creates services, and links /service when absent' do
    allow(FileUtils).to receive(:mkdir_p)
    allow(OsCtl::ExportFS::ErbTemplate).to receive(:render_to)
    allow(File).to receive(:chmod)
    allow(File).to receive(:exist?).with('/service').and_return(false)
    allow(File).to receive(:symlink)

    described_class.run(server, config)

    expect(FileUtils).to have_received(:mkdir_p).with('/etc/runit')
    expect(FileUtils).to have_received(:mkdir_p).with('/etc/runit/runsvdir')
    expect(FileUtils).to have_received(:mkdir_p).with('/etc/runit/runsvdir/rpcbind')
    expect(FileUtils).to have_received(:mkdir_p).with('/etc/runit/runsvdir/nfsd')
    expect(FileUtils).to have_received(:mkdir_p).with('/etc/runit/runsvdir/statd')

    expect(OsCtl::ExportFS::ErbTemplate).to have_received(:render_to)
      .with('runit/1', { server:, config: }, '/etc/runit/1')
    expect(OsCtl::ExportFS::ErbTemplate).to have_received(:render_to)
      .with('runsvdir/nfsd', { server:, config: }, '/etc/runit/runsvdir/nfsd/run')
    expect(File).to have_received(:chmod).with(0o755, '/etc/runit/1')
    expect(File).to have_received(:chmod).with(0o755, '/etc/runit/runsvdir/statd/run')
    expect(File).to have_received(:symlink).with('/etc/runit/runsvdir', '/service')
  end

  it 'does not recreate /service when it already exists' do
    allow(FileUtils).to receive(:mkdir_p)
    allow(OsCtl::ExportFS::ErbTemplate).to receive(:render_to)
    allow(File).to receive(:chmod)
    allow(File).to receive(:exist?).with('/service').and_return(true)
    allow(File).to receive(:symlink)

    described_class.run(server, config)

    expect(File).not_to have_received(:symlink)
  end
end
