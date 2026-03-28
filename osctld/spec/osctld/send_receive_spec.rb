# frozen_string_literal: true

require 'stringio'
require 'osctld/send_receive'

RSpec.describe OsCtld::SendReceive do
  def key_chain_class
    @key_chain_class ||= Class.new do
      def deploy(_io); end

      def started_using_key(_name); end

      def stopped_using_key(_name); end
    end
  end

  def pool_class
    @pool_class ||= Class.new do
      def send_receive_key_chain; end
    end
  end

  let(:pool_a_chain) do
    instance_double(
      key_chain_class,
      deploy: nil,
      started_using_key: nil,
      stopped_using_key: stopped_using_key
    )
  end
  let(:pool_b_chain) do
    instance_double(
      key_chain_class,
      deploy: nil,
      started_using_key: nil,
      stopped_using_key: false
    )
  end
  let(:stopped_using_key) { false }
  let(:pool_a) { instance_double(pool_class, send_receive_key_chain: pool_a_chain) }
  let(:pool_b) { instance_double(pool_class, send_receive_key_chain: pool_b_chain) }

  before do
    stub_const('OsCtld::SendReceive::Server', Class.new do
      def self.start; end

      def self.stop; end

      def self.assets(_add); end
    end)
  end

  it 'starts the server and refreshes the hook symlink during setup' do
    allow(OsCtld::SendReceive::Server).to receive(:start)
    allow(described_class).to receive(:replace_symlink)
    OsCtld.define_singleton_method(:hook_src) { |name| "/hooks/#{name}" }

    described_class.setup

    expect(OsCtld::SendReceive::Server).to have_received(:start).once
    expect(described_class).to have_received(:replace_symlink).with(
      described_class::HOOK,
      '/hooks/send-receive'
    )
  end

  it 'deploys authorized keys from all pools and chowns the file' do
    io = StringIO.new

    stub_const('OsCtld::DB::Pools', Class.new do
      def self.get; end
    end)

    allow(OsCtld::DB::Pools).to receive(:get).and_return([pool_a, pool_b])
    allow(described_class).to receive(:regenerate_file).and_yield(io, nil)
    allow(File).to receive(:chown)

    described_class.deploy

    expect(pool_a_chain).to have_received(:deploy).with(io)
    expect(pool_b_chain).to have_received(:deploy).with(io)
    expect(File).to have_received(:chown).with(
      described_class::UID,
      0,
      described_class::AUTHORIZED_KEYS
    )
  end

  it 'forwards key usage updates to the pool key chain' do
    allow(pool_a_chain).to receive(:started_using_key)

    described_class.started_using_key(pool_a, 'key-a')

    expect(pool_a_chain).to have_received(:started_using_key).with('key-a')
  end

  it 'redeploys keys after the last key usage stops' do
    allow(described_class).to receive(:deploy)
    allow(pool_a_chain).to receive(:stopped_using_key).with('key-a').and_return(true)

    described_class.stopped_using_key(pool_a, 'key-a')

    expect(pool_a_chain).to have_received(:stopped_using_key).with('key-a')
    expect(described_class).to have_received(:deploy).once
  end

  it 'exports the hook, auth keys, and server assets' do
    add_class = Class.new do
      def symlink(*); end

      def file(*); end
    end
    add = instance_double(add_class, symlink: nil, file: nil)

    allow(OsCtld::SendReceive::Server).to receive(:assets)

    described_class.assets(add)

    expect(add).to have_received(:symlink).with(
      described_class::HOOK,
      desc: 'Command run by remote node'
    )
    expect(add).to have_received(:file).with(
      described_class::AUTHORIZED_KEYS,
      desc: 'Keys that are authorized to send containers to this node',
      user: described_class::UID,
      group: 0,
      mode: 0o400,
      optional: true
    )
    expect(OsCtld::SendReceive::Server).to have_received(:assets).with(add)
  end
end
