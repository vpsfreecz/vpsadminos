# frozen_string_literal: true

require 'osctld/send_receive/log'

RSpec.describe OsCtld::SendReceive::Log do
  let(:tokens_class) do
    Class.new do
      def self.free(*); end
    end
  end

  before do
    stub_const('OsCtld::SendReceive::Tokens', tokens_class)
    allow(OsCtld::SendReceive::Tokens).to receive(:free)
  end

  it 'round-trips options and exposes option helpers' do
    options = described_class::Options.load(
      'ctid' => '100',
      'port' => 2222,
      'dst' => 'node',
      'cloned' => true,
      'key_name' => 'main',
      'snapshots' => true,
      'from_snapshot' => 'snap1',
      'preexisting_datasets' => false,
      'protocol_version' => OsCtld::SendReceive::PROTOCOL_VERSION
    )

    expect(options[:ctid]).to eq('100')
    expect(options.cloned?).to be(true)
    expect(options.from_snapshot).to eq('snap1')
    expect(options.protocol_version).to eq(OsCtld::SendReceive::PROTOCOL_VERSION)
    expect(described_class::Options.load(options.dump).dump).to eq(options.dump)
  end

  it 'round-trips logs through dump and load' do
    log = described_class.new(
      role: :source,
      token: 'token-1',
      state: :base,
      snapshots: %w[snap1 snap2],
      state_snapshot: 'cutover-snap',
      state_running: true,
      opts: {
        ctid: '100',
        port: 2222,
        dst: 'node'
      }
    )

    expect(described_class.load(log.dump).dump).to eq(log.dump)
  end

  it 'defaults missing protocol versions to the current version' do
    options = described_class::Options.load(
      'ctid' => '100',
      'port' => 2222,
      'dst' => 'node'
    )

    expect(options.protocol_version).to eq(OsCtld::SendReceive::PROTOCOL_VERSION)
  end

  it 'preserves send-side transition behavior' do
    log = described_class.new(role: :source, token: 'token-1', opts: { ctid: '100', port: 2222, dst: 'node' })

    expect(log.can_send_continue?(:base)).to be(true)
    log.state = :base
    expect(log.can_send_continue?(:base)).to be(false)
    expect(log.can_send_continue?(:incremental)).to be(true)
    log.state = :incremental
    expect(log.can_send_continue?(:incremental)).to be(true)
    expect(log.can_send_continue?(:transfer)).to be(true)
    log.state = :transfer
    expect(log.can_send_continue?(:cleanup)).to be(true)
    expect(log.can_send_continue?(:unknown)).to be(false)
  end

  it 'preserves receive-side transition behavior' do
    log = described_class.new(role: :destination, token: 'token-1', opts: { ctid: '100', port: 2222, dst: 'node' })

    log.state = :base
    expect(log.can_receive_continue?(:base)).to be(true)
    expect(log.can_receive_continue?(:incremental)).to be(true)
    log.state = :incremental
    expect(log.can_receive_continue?(:base)).to be(true)
    expect(log.can_receive_continue?(:cleanup)).to be(true)
    expect(log.can_receive_continue?(:unknown)).to be(false)
  end

  it 'preserves cancel behavior' do
    log = described_class.new(role: :source, token: 'token-1', state: :incremental, opts: { ctid: '100', port: 2222, dst: 'node' })

    expect(log.can_send_cancel?(false)).to be(true)
    expect(log.can_send_cancel?(true)).to be(true)
    expect(log.can_receive_cancel?).to be(true)

    log.state = :transfer
    expect(log.can_send_cancel?(false)).to be(false)
    expect(log.can_send_cancel?(true)).to be(true)
    expect(log.can_receive_cancel?).to be(false)
  end

  it 'rejects invalid states' do
    log = described_class.new(role: :source, token: 'token-1', opts: { ctid: '100', port: 2222, dst: 'node' })

    expect { log.state = :invalid }.to raise_error(RuntimeError, /invalid state/)
  end

  it 'frees tokens when closed' do
    log = described_class.new(role: :source, token: 'token-1', opts: { ctid: '100', port: 2222, dst: 'node' })

    log.close

    expect(OsCtld::SendReceive::Tokens).to have_received(:free).with('token-1')
  end
end
