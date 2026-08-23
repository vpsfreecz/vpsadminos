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
    daemon = instance_double(daemon_class, setup: nil, stop: true)
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

  it 'contains signal-stop errors and permits a later retry' do
    daemon_class = stub_const('OsCtld::Daemon', Class.new do
      def self.create(_path); end
    end)
    daemon = instance_double(daemon_class, setup: nil)
    traps = {}
    allow(Process).to receive(:setproctitle)
    allow(OsCtl::Lib::Logger).to receive(:setup)
    allow(OsCtl::Lib::Logger).to receive(:log)
    allow(daemon_class).to receive(:create).and_return(daemon)
    attempts = 0
    allow(daemon).to receive(:stop) do
      attempts += 1
      raise 'stop failed' if attempts == 1

      false
    end
    allow(Signal).to receive(:trap) { |sig, &block| traps[sig] = block }
    allow(Thread).to receive(:new) do |&block|
      block.call
      instance_double(Thread, join: nil)
    end

    described_class.run(opts)
    expect { traps.fetch('TERM').call }.not_to raise_error
    expect { traps.fetch('TERM').call }.not_to raise_error

    expect(daemon).to have_received(:stop).twice
    expect(OsCtl::Lib::Logger).to have_received(:log).with(
      :fatal,
      'Unable to stop osctld safely: stop failed (RuntimeError)'
    )
  end
end
