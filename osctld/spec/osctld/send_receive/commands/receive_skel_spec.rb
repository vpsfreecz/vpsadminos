# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/IndexedLet, RSpec/LeakyConstantDeclaration, RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles

require 'stringio'
require 'osctld/exceptions'
require 'osctld/send_receive'
require 'osctld/send_receive/command'
require 'osctld/utils/receive'
require 'osctld/send_receive/commands/receive_skel'

RSpec.describe OsCtld::SendReceive::Commands::ReceiveSkel do
  AuthKey = Struct.new(
    :name, :pubkey, :ctid, :single_use_flag, :in_use_flag,
    keyword_init: true
  ) do
    def single_use?
      single_use_flag
    end

    def in_use?
      in_use_flag
    end
  end

  def build_pool(name:, key_chain:, active: true)
    Struct.new(:name, :active_flag, :send_receive_key_chain, keyword_init: true) do
      def active?
        active_flag
      end
    end.new(name:, active_flag: active, send_receive_key_chain: key_chain)
  end

  def build_ct(pool:, id: 'ct1', datasets: [], netifs: [])
    devices = Struct.new(:init_calls) do
      attr_accessor :error

      def check_all_available!
        raise error if error
      end

      def init
        self.init_calls += 1
      end
    end.new(0)
    mounts = Struct.new(:pruned) do
      def prune
        self.pruned = true
      end
    end.new(false)

    Struct.new(
      :id, :pool, :devices, :mounts, :datasets, :netifs, :open_send_log_calls,
      keyword_init: true
    ) do
      def manipulate(_cmd, &)
        yield
      end

      def get_run_conf
        :run_conf
      end

      def open_send_log(*args, **kwargs)
        open_send_log_calls << [args, kwargs]
      end
    end.new(
      id:,
      pool:,
      devices:,
      mounts:,
      datasets:,
      netifs:,
      open_send_log_calls: []
    )
  end

  let(:client_io) { StringIO.new('archive-bytes') }
  let(:client) { double('client', send: nil, recv_io: client_io) }
  let(:handler) { double('handler', socket: client) }
  let(:command) do
    described_class.new(
      {
        key_pool: 'src',
        key_name: 'rx',
        pool: 'dst',
        client_ip: '192.0.2.10',
        passphrase: 'secret',
        protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION
      },
      { handler: }
    )
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  describe '#find_pool_and_key' do
    let(:source_key) { AuthKey.new(name: 'rx', pubkey: 'ssh-rsa AAA', ctid: nil, single_use_flag: false, in_use_flag: false) }
    let(:matched_key) { AuthKey.new(name: 'dst-rx', pubkey: 'ssh-rsa AAA', ctid: nil, single_use_flag: false, in_use_flag: false) }
    let(:source_chain) do
      Struct.new(:key) do
        def get_key(_name)
          key
        end
      end.new(source_key)
    end
    let(:target_chain) do
      Struct.new(:actual_key) do
        def find_key(_pubkey, _hosts, _passphrase)
          actual_key
        end
      end.new(matched_key)
    end
    let(:source_pool) { build_pool(name: 'src', key_chain: source_chain) }
    let(:target_pool) { build_pool(name: 'dst', key_chain: target_chain) }

    before do
      db = stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end
      end)
      allow(db).to receive(:find).with('src').and_return(source_pool)
      allow(db).to receive(:find).with('dst').and_return(target_pool)
      allow(command).to receive(:get_ptr).with('192.0.2.10').and_return('sender.example.test')
    end

    it 'rejects a missing source pool' do
      allow(OsCtld::DB::Pools).to receive(:find).with('src').and_return(nil)

      expect do
        command.send(:find_pool_and_key)
      end.to raise_error(OsCtld::CommandFailed, 'pool not found')
    end

    it 'rejects invalid source and destination authentication keys' do
      allow(source_chain).to receive(:get_key).and_return(nil)

      expect do
        command.send(:find_pool_and_key)
      end.to raise_error(OsCtld::CommandFailed, 'invalid authentication key')

      allow(source_chain).to receive(:get_key).and_return(source_key)
      allow(target_chain).to receive(:find_key).and_return(nil)

      expect do
        command.send(:find_pool_and_key)
      end.to raise_error(OsCtld::CommandFailed, 'invalid authentication key')
    end

    it 'rejects single-use keys that are already in use' do
      target_chain.actual_key = AuthKey.new(
        name: 'dst-rx',
        pubkey: 'ssh-rsa AAA',
        ctid: nil,
        single_use_flag: true,
        in_use_flag: true
      )

      expect do
        command.send(:find_pool_and_key)
      end.to raise_error(OsCtld::CommandFailed, 'invalid authentication key')
    end

    it 'returns the resolved destination pool and matching key' do
      pool, key = command.send(:find_pool_and_key)

      expect(pool).to equal(target_pool)
      expect(key).to equal(matched_key)
    end
  end

  describe '#execute' do
    let(:auth_key) { AuthKey.new(name: 'dst-rx', pubkey: 'ssh-rsa AAA', ctid: nil, single_use_flag: false, in_use_flag: false) }
    let(:archive_type) { 'skel' }
    let(:builder_valid) { true }
    let(:builder_registered) { true }
    let(:key_chain) { Struct.new(:name).new('key-chain') }
    let(:pool) { build_pool(name: 'dst', active: pool_active, key_chain: key_chain) }
    let(:pool_active) { true }
    let(:dataset1) { instance_double(OsCtl::Lib::Zfs::Dataset, name: 'dst/ct1/rootfs') }
    let(:dataset2) { instance_double(OsCtl::Lib::Zfs::Dataset, name: 'dst/ct1/var') }
    let(:ct) { build_ct(pool:, datasets: [dataset1, dataset2], netifs:) }
    let(:netifs) { [] }
    let(:builder) { double('builder') }
    let(:importer) { double('importer') }

    before do
      importer_class = stub_const('OsCtld::Container::Importer', Class.new do
        def initialize(*); end
      end)
      builder_class = stub_const('OsCtld::Container::Builder', Class.new do
        def initialize(*); end
      end)
      stub_const('OsCtld::Commands::User::LxcUsernet', Class.new)
      tokens = stub_const('OsCtld::SendReceive::Tokens', Class.new do
        def self.get; end
      end)
      allow(importer_class).to receive(:new).and_return(importer)
      allow(builder_class).to receive(:new).with(:run_conf).and_return(builder)
      allow(tokens).to receive(:get).and_return('token-123')
      allow(importer).to receive(:load_metadata).and_return('type' => archive_type)
      allow(importer).to receive(:load_ct).with(ct_opts: { staged: true, devices: false }).and_return(ct)
      allow(importer).to receive(:create_datasets)
      allow(importer).to receive(:install_user_hook_scripts)
      allow(builder).to receive_messages(valid?: builder_valid, id_chars: '[a-z0-9]+', register: builder_registered)
      allow(builder).to receive(:setup_lxc_home)
      allow(builder).to receive(:setup_lxc_configs)
      allow(builder).to receive(:setup_log_file)
      allow(builder).to receive(:setup_user_hook_script_dir)
      allow(builder).to receive(:monitor)
      allow(command).to receive(:zfs)
      allow(command).to receive_messages(find_pool_and_key: [pool, auth_key], call_cmd: { status: true, output: nil })
      allow(OsCtld::SendReceive).to receive(:started_using_key)
    end

    it 'sends the continue handshake before importing the archive' do
      command.execute

      expect(client).to have_received(:send).with(%({"status":true,"response":"continue"}\n), 0)
    end

    it 'rejects inactive destination pools' do
      allow(command).to receive(:find_pool_and_key).and_return([build_pool(name: 'dst', active: false, key_chain: key_chain), auth_key])

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'the pool is disabled')
    end

    it 'rejects invalid archive types' do
      allow(importer).to receive(:load_metadata).and_return('type' => 'full')

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, "expected archive type to be 'skel', got 'full'")
    end

    it 'rejects containers outside the permitted ctid glob' do
      auth_key.ctid = 'web*'
      ct.id = 'db1'

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'access denied: invalid container id')
    end

    it 'maps builder registration failure to the expected error' do
      allow(builder).to receive(:register).and_return(false)

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'container dst:ct1 already exists')
    end

    it 'maps device availability failures to command errors' do
      ct.devices.error = OsCtld::DeviceNotAvailable.new(File::NULL, Struct.new(:ident).new('grp'))

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, "device '/dev/null' not available in group 'grp'")
    end

    it 'creates datasets, unmounts them, installs hooks, monitors the container, and opens a destination send log' do
      ct_with_netifs = build_ct(pool:, datasets: [dataset1, dataset2], netifs: [Object.new])
      allow(importer).to receive(:load_ct).and_return(ct_with_netifs)

      expect(command.execute).to eq(status: true, output: 'token-123')
      expect(importer).to have_received(:create_datasets).with(builder, accept_existing: true)
      expect(command).to have_received(:zfs).with(:umount, '', 'dst/ct1/var', valid_rcs: [1])
      expect(command).to have_received(:zfs).with(:umount, '', 'dst/ct1/rootfs', valid_rcs: [1])
      expect(OsCtld::SendReceive).to have_received(:started_using_key).with(pool, 'dst-rx')
      expect(ct_with_netifs.open_send_log_calls).to eq([
                                                         [
                                                           [:destination, 'token-123'],
                                                           {
                                                             key_name: 'dst-rx',
                                                             protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION
                                                           }
                                                         ]
                                                       ])
      expect(importer).to have_received(:install_user_hook_scripts).with(ct_with_netifs)
      expect(builder).to have_received(:monitor)
      expect(command).to have_received(:call_cmd).with(OsCtld::Commands::User::LxcUsernet)
    end

    it 'rejects unsupported protocol versions before receiving the archive' do
      incompatible = described_class.new(
        {
          key_pool: 'src',
          key_name: 'rx',
          pool: 'dst',
          client_ip: '192.0.2.10',
          passphrase: 'secret',
          protocol_version: OsCtld::SendReceive::PROTOCOL_VERSION - 1
        },
        { handler: }
      )

      expect do
        incompatible.base_execute
      end.to raise_error(OsCtld::CommandFailed, %r{unsupported send/receive protocol version})

      expect(client).not_to have_received(:send)
    end
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/IndexedLet, RSpec/LeakyConstantDeclaration, RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles
