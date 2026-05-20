# frozen_string_literal: true

require 'stringio'
require 'yaml'
require 'digest'
require 'libosctl'
require 'osctld/lock_registry'
require 'osctld/send_receive/key_chain'

RSpec.describe OsCtld::SendReceive::KeyChain do
  subject(:key_chain) { key_chain_class.new(pool) }

  let(:root) { Dir.mktmpdir('osctld-key-chain') }
  let(:pool) { build_fake_pool(root: root) }
  let(:key_chain_class) do
    Class.new(described_class) do
      def log(*); end
    end
  end

  after do
    FileUtils.remove_entry(root)
  end

  before do
    FileUtils.mkdir_p(File.join(pool.conf_path, 'send-receive'))
    allow(OsCtld::LockRegistry).to receive(:register)
    stub_const('OsCtld::SendReceive::HOOK', '/run/osctl/send-receive/run')
  end

  it 'round-trips keys and exposes single-use helpers' do
    key = described_class::Key.load(
      'name' => 'main',
      'pubkey' => 'ssh-ed25519 AAAA',
      'from' => 'host.example.com,10.*',
      'ctid' => '100',
      'passphrase' => 'secret',
      'single_use' => true,
      'in_use' => false
    )

    expect(key.dump).to eq(
      'name' => 'main',
      'pubkey' => 'ssh-ed25519 AAAA',
      'from' => 'host.example.com,10.*',
      'ctid' => '100',
      'passphrase' => 'secret',
      'single_use' => true,
      'in_use' => false
    )
    expect(key).to be_single_use
    expect(key).not_to be_in_use
  end

  it 'registers all key-chain assets' do
    collector = Class.new do
      attr_reader :files

      def initialize
        @files = []
      end

      def file(path, **opts)
        @files << [path, opts]
      end
    end.new

    key_chain.assets(collector)

    expect(collector.files).to contain_exactly(
      [key_chain.private_key_path, hash_including(desc: 'Identity private key', mode: 0o400, optional: true)],
      [key_chain.public_key_path, hash_including(desc: 'Identity public key', mode: 0o400, optional: true)],
      [key_chain.key_chain_path, hash_including(desc: 'Keys authorized to send containers to this node', mode: 0o400, optional: true)]
    )
  end

  it 'loads keys from yaml with setup' do
    File.write(
      key_chain.key_chain_path,
      YAML.dump(
        [
          {
            'name' => 'main',
            'pubkey' => 'ssh-ed25519 AAAA',
            'from' => 'host.example.com',
            'ctid' => '100',
            'passphrase' => 'secret',
            'single_use' => false,
            'in_use' => false
          }
        ]
      )
    )

    key_chain.setup

    expect(key_chain.export).to eq(
      [
        {
          'name' => 'main',
          'pubkey' => 'ssh-ed25519 AAAA',
          'from' => 'host.example.com',
          'ctid' => '100',
          'passphrase' => 'secret',
          'single_use' => false,
          'in_use' => false
        }
      ]
    )
  end

  it 'deploys authorized-keys entries' do
    io = StringIO.new

    key_chain.authorize_key('main', 'ssh-ed25519 AAAA')
    key_chain.deploy(io)

    pubkey_hash = Digest::SHA256.hexdigest('ssh-ed25519 AAAA')

    expect(io.string).to include(
      "command=\"/run/osctl/send-receive/run tank main #{pubkey_hash}\",restrict ssh-ed25519 AAAA"
    )
  end

  it 'checks key existence and fetches keys by name' do
    key_chain.authorize_key('main', 'ssh-ed25519 AAAA')

    expect(key_chain.key_exist?('main')).to be(true)
    expect(key_chain.get_key('main').pubkey).to eq('ssh-ed25519 AAAA')
  end

  it 'finds keys by pubkey, host glob, and passphrase' do
    key_chain.authorize_key(
      'main',
      'ssh-ed25519 AAAA',
      from: 'host.example.com,10.*',
      passphrase: 'secret'
    )

    expect(key_chain.find_key('ssh-ed25519 AAAA', ['other.example.com', '10.0.0.1'], 'secret').name).to eq('main')
    expect(key_chain.find_key('ssh-ed25519 AAAA', ['other.example.com'], 'secret')).to be_nil
  end

  it 'disambiguates duplicate public keys by passphrase' do
    key_chain.authorize_key('repeat', 'ssh-ed25519 AAAA', passphrase: 'repeat')
    key_chain.authorize_key('once', 'ssh-ed25519 AAAA', passphrase: 'once')

    expect(key_chain.find_key('ssh-ed25519 AAAA', ['192.0.2.10'], 'repeat').name).to eq('repeat')
    expect(key_chain.find_key('ssh-ed25519 AAAA', ['192.0.2.10'], 'once').name).to eq('once')
  end

  it 'requires an exact passphrase match for passphrase-protected keys' do
    key_chain.authorize_key('main', 'ssh-ed25519 AAAA', passphrase: 'secret')

    expect(key_chain.find_key('ssh-ed25519 AAAA', ['192.0.2.10'], nil)).to be_nil
    expect(key_chain.find_key('ssh-ed25519 AAAA', ['192.0.2.10'], 'wrong')).to be_nil
  end

  it 'matches from restrictions against client addresses and hostnames' do
    key_chain.authorize_key(
      'main',
      'ssh-ed25519 AAAA',
      from: '192.168.10.11,sender.example.test',
      passphrase: 'secret'
    )

    expect(key_chain.find_key('ssh-ed25519 AAAA', ['192.168.10.11'], 'secret').name).to eq('main')
    expect(key_chain.find_key('ssh-ed25519 AAAA', ['192.168.10.12'], 'secret')).to be_nil
    expect(key_chain.find_key('ssh-ed25519 AAAA', ['192.168.10.12', 'sender.example.test'], 'secret').name).to eq('main')
  end

  it 'rejects duplicate key names' do
    key_chain.authorize_key('main', 'ssh-ed25519 AAAA')

    expect { key_chain.authorize_key('main', 'ssh-ed25519 BBBB') }.to raise_error(ArgumentError, 'key exists')
  end

  it 'revokes keys by name' do
    key_chain.authorize_key('main', 'ssh-ed25519 AAAA')
    key_chain.revoke_key('main')

    expect(key_chain.export).to eq([])
  end

  it 'marks single-use keys in use and saves them' do
    key_chain.authorize_key('main', 'ssh-ed25519 AAAA', single_use: true)

    expect(key_chain.started_using_key('main')).to be(true)

    yaml = OsCtl::Lib::ConfigFile.load_yaml_file(key_chain.key_chain_path)

    expect(yaml).to eq(
      [
        {
          'name' => 'main',
          'pubkey' => 'ssh-ed25519 AAAA',
          'from' => nil,
          'ctid' => nil,
          'passphrase' => nil,
          'single_use' => true,
          'in_use' => true
        }
      ]
    )
  end

  it 'removes single-use keys when they stop being used' do
    key_chain.authorize_key('main', 'ssh-ed25519 AAAA', single_use: true)
    key_chain.started_using_key('main')

    expect(key_chain.stopped_using_key('main')).to be(true)
    expect(key_chain.export).to eq([])
    expect(OsCtl::Lib::ConfigFile.load_yaml_file(key_chain.key_chain_path)).to eq([])
  end

  it 'exports keys and saves them to yaml' do
    key_chain.authorize_key('main', 'ssh-ed25519 AAAA', passphrase: 'secret')
    key_chain.save

    expect(key_chain.export).to eq(
      [
        {
          'name' => 'main',
          'pubkey' => 'ssh-ed25519 AAAA',
          'from' => nil,
          'ctid' => nil,
          'passphrase' => 'secret',
          'single_use' => nil,
          'in_use' => false
        }
      ]
    )
    expect(OsCtl::Lib::ConfigFile.load_yaml_file(key_chain.key_chain_path)).to eq(key_chain.export)
  end
end
