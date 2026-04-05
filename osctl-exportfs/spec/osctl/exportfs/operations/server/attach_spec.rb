# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Server::Attach do
  let(:server) { instance_double(OsCtl::ExportFS::Server, name: 'srv') }

  before do
    allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(server)
  end

  it 'runs bash inside the server namespaces with the expected environment' do
    op = described_class.new('srv')
    allow(op).to receive(:syscmd).and_return(build_command_result(output: "/nix/store/bash\n"))
    allow(OsCtl::ExportFS::Operations::Server::Exec).to receive(:run) do |_server, &block|
      block.call
    end
    allow(Process).to receive(:exec)

    old_path = ENV.fetch('PATH', nil)
    old_ps1 = ENV.fetch('PS1', nil)

    op.execute

    expect(OsCtl::ExportFS::Operations::Server::Exec).to have_received(:run).with(server)
    expect(ENV.fetch('PATH', nil)).to end_with(':/run/current-system/sw/bin')
    expect(ENV.fetch('PS1', nil)).to eq('[NFSD srv]# ')
    expect(Process).to have_received(:exec).with('/nix/store/bash/bin/bash', '--norc')
  ensure
    ENV['PATH'] = old_path
    ENV['PS1'] = old_ps1
  end

  it 'resolves bashInteractive via nix-build output' do
    op = described_class.new('srv')
    allow(op).to receive(:syscmd).and_return(build_command_result(output: "/nix/store/bash\n"))

    expect(op.send(:bash_interactive)).to eq('/nix/store/bash')
  end
end
