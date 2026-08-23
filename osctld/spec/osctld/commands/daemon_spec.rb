# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubles

require 'osctld/exceptions'
require 'osctld/command'

module OsCtld
  module Commands
    module Daemon; end
  end
end

require 'osctld/commands/daemon/status'
require 'osctld/commands/daemon/prepare_stop'
require 'osctld/commands/daemon/resume'
require 'osctld/commands/daemon/wait_ready'

RSpec.describe 'daemon lifecycle commands' do
  before do
    daemon_class = stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(daemon_class).to receive(:get).and_return(daemon)
  end

  let(:restart_config) { Struct.new(:recovery_timeout).new(300) }
  let(:daemon_config) { Struct.new(:restart).new(restart_config) }
  let(:status) { { phase: 'ready', ready: true } }
  let(:daemon) do
    double(
      'Daemon',
      config: daemon_config,
      status:,
      prepare_stop: true,
      resume: true,
      wait_ready: true
    )
  end

  it 'returns daemon status' do
    expect(OsCtld::Commands::Daemon::Status.run).to eq(
      status: true,
      output: status
    )
  end

  it 'prepares and resumes lifecycle admission' do
    expect(OsCtld::Commands::Daemon::PrepareStop.run).to eq(
      status: true,
      output: status
    )
    expect(OsCtld::Commands::Daemon::Resume.run).to eq(
      status: true,
      output: status
    )
  end

  it 'passes the requested readiness timeout' do
    expect(OsCtld::Commands::Daemon::WaitReady.run(timeout: 42)).to eq(
      status: true,
      output: status
    )
    expect(daemon).to have_received(:wait_ready).with(timeout: 42)
  end

  it 'does not claim a clean drain when preparation fails' do
    allow(daemon).to receive(:prepare_stop).and_return(false)

    expect(OsCtld::Commands::Daemon::PrepareStop.run).to eq(
      status: false,
      message: 'container lifecycle drain did not complete safely'
    )
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/VerifiedDoubles
