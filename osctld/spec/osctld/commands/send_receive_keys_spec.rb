# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/DescribeClass, RSpec/LeakyConstantDeclaration

require 'osctld/exceptions'
require 'osctld/command'

module OsCtld
  module Commands
    module Send; end
    module Receive; end
  end
end

require 'osctld/commands/send/key_gen'
require 'osctld/commands/send/key_path'
require 'osctld/commands/receive/authkey_add'
require 'osctld/commands/receive/authkey_delete'
require 'osctld/commands/receive/authkey_list'

RSpec.describe 'send/receive key commands' do
  class FakeKeyChain
    attr_reader :private_key_path, :public_key_path, :export
    attr_accessor :authorized, :revoked, :saved, :existing

    def initialize(private_key_path:, public_key_path:, export:)
      @private_key_path = private_key_path
      @public_key_path = public_key_path
      @export = export
      @authorized = nil
      @revoked = nil
      @saved = false
      @existing = nil
    end

    def key_exist?(name)
      existing == name
    end

    def authorize_key(*args, **kwargs)
      self.authorized = [args, kwargs]
    end

    def revoke_key(name)
      self.revoked = name
    end

    def save
      self.saved = true
    end
  end

  let(:key_chain) do
    FakeKeyChain.new(
      private_key_path: '/keys/id_send',
      public_key_path: '/keys/id_send.pub',
      export: [{ name: 'rx' }]
    )
  end
  let(:pool) do
    Struct.new(:name, :send_receive_key_chain).new('tank', key_chain).tap do |obj|
      obj.define_singleton_method(:pool) { self }
    end
  end

  before do
    pools = stub_const('OsCtld::DB::Pools', Class.new do
      def self.find(_name); end

      def self.get_or_default(_name); end
    end)
    history = stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
    send_receive = stub_const('OsCtld::SendReceive', Module.new)
    send_receive.define_singleton_method(:deploy) { nil }

    allow(pools).to receive(:find).with('tank').and_return(pool)
    allow(pools).to receive(:get_or_default).with(nil).and_return(pool)
    allow(history).to receive(:log)
    allow(OsCtld::SendReceive).to receive(:deploy)
  end

  describe OsCtld::Commands::Send::KeyGen do
    it 'removes existing files, uses the default ed25519 parameters, and chmods the results' do
      command = described_class.new({ pool: 'tank' }, {})
      allow(Socket).to receive(:gethostname).and_return('node1')
      allow(FileUtils).to receive(:rm_f)
      allow(File).to receive(:chmod)
      allow(command).to receive(:syscmd)

      expect(command.execute(pool)).to eq(status: true, output: nil)
      expect(FileUtils).to have_received(:rm_f).with('/keys/id_send').once
      expect(FileUtils).to have_received(:rm_f).with('/keys/id_send.pub').once
      expect(command).to have_received(:syscmd).with(
        "ssh-keygen -q -t ed25519 -b 4096 -N '' -C 'tank@node1' -f /keys/id_send"
      )
      expect(File).to have_received(:chmod).with(0o400, '/keys/id_send')
      expect(File).to have_received(:chmod).with(0o400, '/keys/id_send.pub')
    end

    it 'uses the selected key type and default bit size for ecdsa' do
      command = described_class.new({ pool: 'tank', type: 'ecdsa' }, {})
      allow(Socket).to receive(:gethostname).and_return('node1')
      allow(FileUtils).to receive(:rm_f)
      allow(File).to receive(:chmod)
      allow(command).to receive(:syscmd)

      command.execute(pool)

      expect(command).to have_received(:syscmd).with(
        "ssh-keygen -q -t ecdsa -b 521 -N '' -C 'tank@node1' -f /keys/id_send"
      )
    end
  end

  describe OsCtld::Commands::Send::KeyPath do
    it 'returns the pool send key paths' do
      expect(described_class.run(pool: 'tank')).to eq(
        status: true,
        output: {
          private_key: '/keys/id_send',
          public_key: '/keys/id_send.pub'
        }
      )
    end
  end

  describe OsCtld::Commands::Receive::AuthKeyAdd do
    it 'validates the key name and passphrase format' do
      expect do
        described_class.run!(pool: 'tank', name: 'bad key', public_key: 'ssh-rsa AAA')
      end.to raise_error(OsCtld::CommandFailed, 'key name must consist only of a-z A-Z 0-9, _-:.')

      expect do
        described_class.run!(pool: 'tank', name: 'good', public_key: 'ssh-rsa AAA', passphrase: 'bad phrase')
      end.to raise_error(OsCtld::CommandFailed, 'passphrase must consist only of a-z A-Z 0-9, _-:.')
    end

    it 'rejects duplicate key names' do
      key_chain.existing = 'rx'

      expect do
        described_class.run!(pool: 'tank', name: 'rx', public_key: 'ssh-rsa AAA')
      end.to raise_error(OsCtld::CommandFailed, "key 'rx' already exists")
    end

    it 'authorizes the key, saves the keychain, and deploys send-receive config' do
      ret = described_class.run(
        pool: 'tank',
        name: 'rx',
        public_key: 'ssh-rsa AAA',
        from: ['192.0.2.0/24'],
        ctid: 'web*',
        passphrase: 'secret',
        single_use: true
      )

      expect(ret).to eq(status: true, output: nil)
      expect(key_chain.authorized).to eq([
                                           ['rx', 'ssh-rsa AAA'],
                                           {
                                             from: ['192.0.2.0/24'],
                                             ctid: 'web*',
                                             passphrase: 'secret',
                                             single_use: true
                                           }
                                         ])
      expect(key_chain.saved).to be(true)
      expect(OsCtld::SendReceive).to have_received(:deploy)
    end
  end

  describe OsCtld::Commands::Receive::AuthKeyDelete do
    it 'revokes the key, saves the keychain, and redeploys send-receive config' do
      ret = described_class.run(pool: 'tank', name: 'rx')

      expect(ret).to eq(status: true, output: nil)
      expect(key_chain.revoked).to eq('rx')
      expect(key_chain.saved).to be(true)
      expect(OsCtld::SendReceive).to have_received(:deploy)
    end
  end

  describe OsCtld::Commands::Receive::AuthKeyList do
    it 'exports the pool receive auth keys' do
      expect(described_class.run(pool: 'tank')).to eq(status: true, output: [{ name: 'rx' }])
    end
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/DescribeClass, RSpec/LeakyConstantDeclaration
