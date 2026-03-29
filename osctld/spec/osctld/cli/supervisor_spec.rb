# frozen_string_literal: true

module OsCtld
  module Cli; end
end

require 'osctld/cli/daemon'
require 'osctld/cli/supervisor'

RSpec.describe OsCtld::Cli::Supervisor do
  it 'parses defaults and overrides' do
    with_argv('--no-supervisor', '--config', '/etc/osctld.conf', '--log', 'syslog', '--log-facility', 'local0') do
      supervisor = described_class.new
      opts = supervisor.parse

      expect(opts.supervisor).to be(false)
      expect(opts.config).to eq('/etc/osctld.conf')
      expect(opts.log).to eq(:syslog)
      expect(opts.log_facility).to eq('local0')
    end
  end

  it 'exits when config is missing' do
    with_argv do
      expect do
        described_class.new.parse
      end.to raise_error(SystemExit)
    end
  end

  it 'delegates directly to Cli::Daemon when supervisor is disabled' do
    allow(OsCtld::Cli::Daemon).to receive(:run)

    with_argv('--no-supervisor', '--config', '/etc/osctld.conf') do
      described_class.run
    end

    expect(OsCtld::Cli::Daemon).to have_received(:run).with(
      have_attributes(
        supervisor: false,
        config: '/etc/osctld.conf',
        log: :stdout,
        log_facility: 'daemon'
      )
    )
  end

  it 'removes daemon and user-control sockets during cleanup' do
    with_tmpdir do |tmpdir|
      daemon_socket = File.join(tmpdir, 'osctld.sock')
      user_control_dir = File.join(tmpdir, 'user-control')
      send_receive_socket = File.join(tmpdir, 'send-receive.sock')
      FileUtils.mkdir_p(user_control_dir)
      File.write(daemon_socket, '')
      File.write(send_receive_socket, '')
      stale = File.join(user_control_dir, 'ct1.sock')
      File.write(stale, '')

      stub_const('OsCtld::Daemon', Class.new)
      stub_const('OsCtld::RunState', Module.new)
      stub_const('OsCtld::SendReceive', Module.new)
      stub_const('OsCtld::Daemon::SOCKET', daemon_socket)
      stub_const('OsCtld::RunState::USER_CONTROL_DIR', user_control_dir)
      stub_const('OsCtld::SendReceive::SOCKET', send_receive_socket)

      described_class.new.cleanup

      expect(File.exist?(daemon_socket)).to be(false)
      expect(File.exist?(stale)).to be(false)
      expect(File.exist?(send_receive_socket)).to be(false)
    end
  end
end
