# frozen_string_literal: true

require 'osctld/send_receive'
require 'osctld/send_receive/command'
require 'osctld/utils/receive'
require 'osctld/send_receive/commands/receive_transfer'

RSpec.describe OsCtld::SendReceive::Commands::Transfer do
  def build_send_log
    send_log_opts_class = Struct.new(:key_name, keyword_init: true)
    Struct.new(:snapshots, :opts, keyword_init: true) do
      def can_receive_continue?(_stage)
        true
      end
    end.new(
      snapshots: [['tank/ct1', 'snap1']],
      opts: send_log_opts_class.new(key_name: 'auth-key')
    )
  end

  def build_ct(pool, send_log)
    Class.new do
      attr_accessor :state
      attr_reader :pool, :id, :send_log, :closed

      def initialize(pool, send_log)
        @pool = pool
        @send_log = send_log
        @id = 'ct1'
        @state = :staged
        @closed = false
      end

      def manipulate(_cmd, block:, &)
        yield
      end

      def close_send_log
        @closed = true
      end
    end.new(pool, send_log)
  end

  let(:pool) do
    Struct.new(:name, keyword_init: true) do
      def active?
        true
      end
    end.new(name: 'tank')
  end
  let(:ct) do
    build_ct(pool, build_send_log)
  end
  let(:command) do
    described_class.new(
      { token: 'abc', key_pool: 'tank', key_name: 'rx', start: start_container },
      {}
    )
  end
  let(:start_container) { false }

  before do
    stub_const('OsCtld::SendReceive::Tokens', Class.new do
      def self.find_container(_token); end
    end)
    stub_const('OsCtld::Commands::Container::Start', Class.new)
    allow(OsCtld::SendReceive::Tokens).to receive(:find_container).with('abc').and_return(ct)
    allow(command).to receive_messages(
      check_auth_pubkey: true,
      zfs: nil,
      call_cmd!: { status: true, output: nil }
    )
    allow(OsCtld::SendReceive).to receive(:stopped_using_key)
  end

  it 'marks the transfer complete and cleans up snapshots and key usage' do
    expect(command.execute).to eq(status: true, output: nil)
    expect(ct.state).to eq(:complete)
    expect(command).to have_received(:zfs).with(:destroy, nil, 'tank/ct1@snap1')
    expect(OsCtld::SendReceive).to have_received(:stopped_using_key).with(pool, 'auth-key')
    expect(ct.closed).to be(true)
  end

  it 'optionally starts the completed container' do
    allow(command).to receive(:call_cmd!).and_return(status: true, output: nil)
    command_with_start = described_class.new(
      { token: 'abc', key_pool: 'tank', key_name: 'rx', start: true },
      {}
    )
    allow(command_with_start).to receive_messages(
      check_auth_pubkey: true,
      zfs: nil,
      call_cmd!: { status: true, output: nil }
    )
    allow(OsCtld::SendReceive::Tokens).to receive(:find_container).with('abc').and_return(ct)
    allow(OsCtld::SendReceive).to receive(:stopped_using_key)

    command_with_start.execute

    expect(command_with_start).to have_received(:call_cmd!).with(
      OsCtld::Commands::Container::Start,
      id: 'ct1',
      pool: 'tank',
      force: true
    )
  end
end
