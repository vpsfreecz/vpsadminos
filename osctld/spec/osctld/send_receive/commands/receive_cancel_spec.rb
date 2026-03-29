# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/send_receive'
require 'osctld/send_receive/command'
require 'osctld/utils/receive'
require 'osctld/send_receive/commands/receive_cancel'

RSpec.describe OsCtld::SendReceive::Commands::ReceiveCancel do
  def build_send_log
    send_log_opts_class = Struct.new(:key_name, keyword_init: true)
    Struct.new(:snapshots, :opts, keyword_init: true) do
      def can_receive_cancel?
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

  let(:pool) { Struct.new(:name, keyword_init: true).new(name: 'tank') }
  let(:ct) do
    build_ct(pool, build_send_log)
  end
  let(:command) { described_class.new({ token: 'abc', key_pool: 'tank', key_name: 'rx' }, {}) }

  before do
    stub_const('OsCtld::SendReceive::Tokens', Class.new do
      def self.find_container(_token); end
    end)
    stub_const('OsCtld::Commands::Container::Delete', Class.new)
    allow(OsCtld::SendReceive::Tokens).to receive(:find_container).with('abc').and_return(ct)
    allow(command).to receive_messages(
      check_auth_pubkey: true,
      zfs: nil,
      call_cmd!: { status: true, output: nil }
    )
    allow(OsCtld::SendReceive).to receive(:stopped_using_key)
  end

  it 'cancels a staged receive, destroys snapshots, and deletes the staged ct' do
    expect(command.execute).to eq(status: true, output: nil)
    expect(command).to have_received(:zfs).with(:destroy, nil, 'tank/ct1@snap1')
    expect(OsCtld::SendReceive).to have_received(:stopped_using_key).with(pool, 'auth-key')
    expect(command).to have_received(:call_cmd!).with(
      OsCtld::Commands::Container::Delete,
      id: 'ct1',
      pool: 'tank'
    )
    expect(ct.closed).to be(true)
  end

  it 'rejects containers that cannot be found' do
    allow(OsCtld::SendReceive::Tokens).to receive(:find_container).with('abc').and_return(nil)

    expect { command.execute }.to raise_error(OsCtld::CommandFailed, 'container not found')
  end

  it 'rejects invalid send sequences and authentication key mismatches' do
    allow(ct.send_log).to receive(:can_receive_cancel?).and_return(false)

    expect { command.execute }.to raise_error(OsCtld::CommandFailed, 'invalid send sequence')

    allow(ct.send_log).to receive(:can_receive_cancel?).and_return(true)
    allow(command).to receive(:check_auth_pubkey).and_return(false)

    expect { command.execute }.to raise_error(OsCtld::CommandFailed, 'authentication key mismatch')
  end
end
