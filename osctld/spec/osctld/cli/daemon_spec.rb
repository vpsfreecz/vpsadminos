# frozen_string_literal: true

module OsCtld
  module Cli; end
end

require 'osctld/cli/daemon'

RSpec.describe OsCtld::Cli::Daemon do
  let(:opts) { Struct.new(:log, :log_facility, :config).new(:stdout, 'daemon', '/etc/osctld.conf') }

  it 'sets up logging, creates the daemon, and traps stop signals once' do
    daemon_class = stub_const('OsCtld::Daemon', Class.new do
      def self.create(_path); end
    end)
    daemon = instance_double(daemon_class, setup: nil, stop: nil)
    traps = {}
    allow(Process).to receive(:setproctitle)
    allow(OsCtl::Lib::Logger).to receive(:setup)
    allow(daemon_class).to receive(:create).and_return(daemon)
    allow(Signal).to receive(:trap) { |sig, &block| traps[sig] = block }
    allow(Thread).to receive(:new) do |&block|
      block.call
      instance_double(Thread, join: nil)
    end

    described_class.run(opts)
    traps.fetch('INT').call
    traps.fetch('TERM').call

    expect(Process).to have_received(:setproctitle).with('osctld: main')
    expect(OsCtl::Lib::Logger).to have_received(:setup).with(:stdout, facility: 'daemon')
    expect(daemon_class).to have_received(:create).with('/etc/osctld.conf')
    expect(daemon).to have_received(:setup)
    expect(daemon).to have_received(:stop).once
  end
end
