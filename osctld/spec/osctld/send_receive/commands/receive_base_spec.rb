# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles

require 'osctld/exceptions'
require 'osctld/send_receive'
require 'osctld/send_receive/command'
require 'osctld/utils/receive'
require 'osctld/send_receive/commands/receive_base'

RSpec.describe OsCtld::SendReceive::Commands::ReceiveBase do
  def stub_receive_daemon
    mbuffer_cfg = Struct.new(:command) do
      def as_cli_options
        ['-m', '128M']
      end
    end.new('mbuffer')
    send_receive_cfg = Struct.new(:receive_mbuffer).new(mbuffer_cfg)
    daemon_cfg = Struct.new(:send_receive).new(send_receive_cfg)
    daemon = Struct.new(:config).new(daemon_cfg)

    stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
  end

  def build_ct
    send_log_opts = Struct.new(:key_name, :protocol_version).new(
      'auth-key',
      OsCtld::SendReceive::PROTOCOL_VERSION
    )
    send_log = Struct.new(:state, :snapshots, :opts) do
      def can_receive_continue?(stage)
        stage == :base
      end

      def protocol_version
        opts.protocol_version
      end
    end.new(nil, [], send_log_opts)
    dataset = instance_double(OsCtl::Lib::Zfs::Dataset, name: 'tank/ct1')

    Struct.new(
      :config_state, :send_log, :dataset, :save_config_calls,
      keyword_init: true
    ) do
      def manipulate(_cmd, block:, &)
        yield
      end

      def exclusively(&block)
        block.call
      end

      def save_config
        self.save_config_calls += 1
      end
    end.new(config_state: :staged, send_log:, dataset:, save_config_calls: 0)
  end

  let(:ct) { build_ct }
  let(:client_io) { instance_double(IO, close: nil) }
  let(:client) { double('client', send: nil, recv_io: client_io) }
  let(:handler) { double('handler', socket: client) }
  let(:command) do
    described_class.new(
      {
        token: 'token',
        key_pool: 'tank',
        key_name: 'rx',
        dataset: '/',
        snapshot: 'snap1',
        protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION
      },
      { handler: }
    )
  end

  before do
    stub_receive_daemon
    dataset = instance_double(OsCtl::Lib::Zfs::Dataset, name: 'tank/ct1', exist?: true)
    allow(OsCtl::Lib::Zfs::Dataset).to receive(:new).and_return(dataset)
    allow(command).to receive(:check_auth_pubkey).and_return(true)
    stub_const('OsCtld::SendReceive::Tokens', Class.new do
      def self.find_container(_token); end
    end)
    allow(OsCtld::SendReceive::Tokens).to receive(:find_container).with('token').and_return(ct)
    r = instance_double(IO, close: nil)
    w = instance_double(IO, close: nil)
    allow(IO).to receive(:pipe).and_return([r, w])
    allow(Process).to receive(:spawn).and_return(11, 12)
  end

  it 'sends the continue handshake and persists receive state when both processes succeed' do
    allow(Process).to receive(:wait2).with(11).and_return([11, build_wait_status(0)])
    allow(Process).to receive(:wait2).with(12).and_return([12, build_wait_status(0)])

    expect(command.execute).to eq(status: true, output: nil)
    expect(client).to have_received(:send).with(%({"status":true,"response":"continue"}\n), 0)
    expect(ct.send_log.state).to eq(:base)
    expect(ct.send_log.snapshots).to eq([['tank/ct1', 'snap1']])
    expect(ct.save_config_calls).to eq(1)
  end

  it 'fails when mbuffer exits non-zero even if zfs recv succeeds' do
    allow(Process).to receive(:wait2).with(11).and_return([11, build_wait_status(2)])
    allow(Process).to receive(:wait2).with(12).and_return([12, build_wait_status(0)])

    expect(command.execute).to eq(
      status: false,
      message: 'unable to receive stream, mbuffer exited with 2'
    )
    expect(ct.send_log.state).to be_nil
    expect(ct.save_config_calls).to eq(0)
  end

  it 'reports both pipeline failures when mbuffer and zfs recv exit non-zero' do
    allow(Process).to receive(:wait2).with(11).and_return([11, build_wait_status(2)])
    allow(Process).to receive(:wait2).with(12).and_return([12, build_wait_status(3)])

    expect(command.execute).to eq(
      status: false,
      message: 'unable to receive stream, mbuffer exited with 2 and zfs recv exited with 3'
    )
  end

  it 'maps the root dataset path and nested dataset names correctly' do
    expect(command.send(:dataset_name, ct)).to eq('tank/ct1')

    nested = described_class.new(
      { token: 'token', key_pool: 'tank', key_name: 'rx', dataset: 'rootfs/var' },
      { handler: }
    )

    expect(nested.send(:dataset_name, ct)).to eq('tank/ct1/rootfs/var')
  end

  it 'rejects send-log protocol mismatches' do
    ct.send_log.opts.protocol_version = OsCtld::SendReceive::PROTOCOL_VERSION - 1

    expect do
      command.base_execute
    end.to raise_error(OsCtld::CommandFailed, %r{send/receive protocol version mismatch})
  end
end

# rubocop:enable RSpec/VerifiedDoubles
