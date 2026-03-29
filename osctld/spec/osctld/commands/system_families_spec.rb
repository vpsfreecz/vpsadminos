# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubles

require 'socket'
require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/utils/assets'
require 'osctld/utils/switch_user'

module OsCtld
  module Commands
    module Self; end
    module Debug; end
    module Receive; end
    module Send; end
    module CpuScheduler; end
    module User; end
  end
end

require 'osctld/commands/self/abort_shutdown'
require 'osctld/commands/self/activate'
require 'osctld/commands/self/assets'
require 'osctld/commands/self/health_check'
require 'osctld/commands/self/status'
require 'osctld/commands/debug/thread_list'
require 'osctld/commands/debug/ugid_registry'
require 'osctld/commands/receive/authkey_add'
require 'osctld/commands/receive/authkey_delete'
require 'osctld/commands/send/key_gen'
require 'osctld/commands/cpu_scheduler/disable'
require 'osctld/commands/cpu_scheduler/enable'
require 'osctld/commands/cpu_scheduler/package_disable'
require 'osctld/commands/cpu_scheduler/package_enable'
require 'osctld/commands/cpu_scheduler/package_list'
require 'osctld/commands/cpu_scheduler/status'
require 'osctld/commands/cpu_scheduler/upkeep'

RSpec.describe 'system command families' do
  def stub_history
    stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
  end

  before do
    allow(stub_history).to receive(:log)
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  describe OsCtld::Commands::Self::AbortShutdown do
    it 'delegates shutdown abort to the daemon' do
      daemon = double('Daemon', abort_shutdown: nil)
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon_class).to receive(:get).and_return(daemon)

      expect(described_class.run).to eq(status: true, output: nil)
      expect(daemon).to have_received(:abort_shutdown)
    end
  end

  describe OsCtld::Commands::Self::Activate do
    let(:subugids_class) { stub_const('OsCtld::Commands::User::SubUGIds', Class.new) }
    let(:usernet_class) { stub_const('OsCtld::Commands::User::LxcUsernet', Class.new) }

    it 'regenerates user system files when requested' do
      command = described_class.new({ system: true }, {})
      allow(command).to receive(:call_cmd).with(subugids_class).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd).with(usernet_class).and_return(status: true, output: nil)

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:call_cmd).with(subugids_class)
      expect(command).to have_received(:call_cmd).with(usernet_class)
    end
  end

  describe OsCtld::Commands::Self::Assets do
    it 'returns validated daemon assets' do
      daemon = double('Daemon')
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon_class).to receive(:get).and_return(daemon)
      command = described_class.new({}, {})
      allow(command).to receive(:list_and_validate_assets).with(daemon).and_return([{ path: '/run/osctld.sock' }])

      expect(command.execute).to eq(status: true, output: [{ path: '/run/osctld.sock' }])
    end
  end

  describe OsCtld::Commands::Self::HealthCheck do
    it 'collects invalid assets from the daemon and selected pools' do
      validator_class = stub_const('OsCtld::Assets::Validator', Class.new do
        def self.new; end
      end)
      validator = instance_double(validator_class, add_assets: nil, validate: nil)
      allow(validator_class).to receive(:new).and_return(validator)
      daemon_asset = Struct.new(:state, :type, :path, :opts, :errors).new(:invalid, 'socket', '/run/osctld.sock', {}, ['missing'])
      daemon = double('Daemon', assets: [daemon_asset])
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      pool = Struct.new(:name) do
        def pool
          self
        end

        def assets
          []
        end

        def id
          name
        end
      end.new('tank')
      entity_class = stub_const('SpecHealthContainer', Class.new do
        attr_reader :pool, :id

        def initialize(pool, id)
          @pool = pool
          @id = id
        end

        def assets
          [Struct.new(:state, :type, :path, :opts, :errors).new(:invalid, 'config', '/etc/ct.yml', {}, ['broken'])]
        end
      end)
      entity = entity_class.new(pool, 'ct1')
      pools_class = stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end

        def self.get; end
      end)
      repos_class = stub_const('OsCtld::DB::Repositories', Class.new do
        def self.get; end
      end)
      users_class = stub_const('OsCtld::DB::Users', Class.new do
        def self.get; end
      end)
      groups_class = stub_const('OsCtld::DB::Groups', Class.new do
        def self.get; end
      end)
      cts_class = stub_const('OsCtld::DB::Containers', Class.new do
        def self.get; end
      end)
      allow(daemon_class).to receive(:get).and_return(daemon)
      allow(pools_class).to receive(:find).with('tank').and_return(pool)
      allow(pools_class).to receive(:get).and_return([pool])
      allow(repos_class).to receive(:get).and_return([])
      allow(users_class).to receive(:get).and_return([])
      allow(groups_class).to receive(:get).and_return([])
      allow(cts_class).to receive(:get).and_return([entity])

      expect(described_class.run(pools: ['tank'])).to eq(
        status: true,
        output: [
          {
            pool: nil,
            type: 'osctld',
            id: nil,
            assets: [
              {
                type: 'socket',
                path: '/run/osctld.sock',
                opts: {},
                errors: ['missing']
              }
            ]
          },
          {
            pool: 'tank',
            type: 'spechealthcontainer',
            id: 'ct1',
            assets: [
              {
                type: 'config',
                path: '/etc/ct.yml',
                opts: {},
                errors: ['broken']
              }
            ]
          }
        ]
      )
      expect(validator).to have_received(:add_assets).with([daemon_asset])
    end
  end

  describe OsCtld::Commands::Self::Status do
    it 'exports daemon start and initialization state' do
      daemon = double('Daemon', started_at: Time.at(123), initialized: true)
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end
      end)
      allow(daemon_class).to receive(:get).and_return(daemon)

      expect(described_class.run).to eq(
        status: true,
        output: { started_at: 123, initialized: true }
      )
    end
  end

  describe OsCtld::Commands::Debug::ThreadList do
    it 'exports thread metadata with denixstorified backtraces' do
      thread = double('Thread', to_s: '#<Thread:1>', backtrace: ['/nix/store/foo', '/tmp/bar'])
      manager = double('Manager', to_s: '#<Manager:1>')
      thread_reaper = stub_const('OsCtld::ThreadReaper', Class.new do
        def self.export; end
      end)
      allow(thread_reaper).to receive(:export).and_return([[thread, manager]])
      command = described_class.new({}, {})
      allow(command).to receive(:denixstorify).with(['/nix/store/foo', '/tmp/bar']).and_return(%w[foo bar])

      expect(command.execute).to eq(
        status: true,
        output: [{ thread: '#<Thread:1>', manager: '#<Manager:1>', backtrace: %w[foo bar] }]
      )
    end
  end

  describe OsCtld::Commands::Debug::UGidRegistry do
    it 'exports the ugid registry through the correctly named command class' do
      registry = stub_const('OsCtld::UGidRegistry', Class.new do
        def self.export; end
      end)
      allow(registry).to receive(:export).and_return([1000, 1001])

      expect(described_class.run).to eq(status: true, output: [1000, 1001])
      expect(OsCtld::Command.find(:debug_ugid_registry)).to eq(described_class)
    end
  end

  describe OsCtld::Commands::Receive::AuthKeyAdd do
    def stub_pools
      stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end

        def self.get_or_default(_name); end
      end)
    end

    it 'validates names, authorizes the key, saves, and deploys' do
      pools = stub_pools
      deployer = stub_const('OsCtld::SendReceive', Class.new do
        def self.deploy; end
      end)
      key_chain = double('KeyChain', key_exist?: false, authorize_key: nil, save: nil)
      pool = Struct.new(:send_receive_key_chain, :name) do
        def pool
          self
        end
      end.new(key_chain, 'tank')
      allow(pools).to receive(:find).with('tank').and_return(pool)
      allow(deployer).to receive(:deploy)

      expect(
        described_class.run(
          pool: 'tank',
          name: 'rx',
          public_key: 'ssh-ed25519 AAA',
          from: ['1.2.3.4'],
          ctid: 'ct1',
          passphrase: 'secret',
          single_use: true
        )
      ).to eq(status: true, output: nil)
      expect(key_chain).to have_received(:authorize_key).with(
        'rx',
        'ssh-ed25519 AAA',
        from: ['1.2.3.4'],
        ctid: 'ct1',
        passphrase: 'secret',
        single_use: true
      )
      expect(key_chain).to have_received(:save)
      expect(deployer).to have_received(:deploy)
    end
  end

  describe OsCtld::Commands::Receive::AuthKeyDelete do
    it 'revokes the key, saves, and deploys changes' do
      pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end
      end)
      deployer = stub_const('OsCtld::SendReceive', Class.new do
        def self.deploy; end
      end)
      key_chain = double('KeyChain', revoke_key: nil, save: nil)
      pool = Struct.new(:send_receive_key_chain, :name) do
        def pool
          self
        end
      end.new(key_chain, 'tank')
      allow(pools).to receive(:find).with('tank').and_return(pool)
      allow(deployer).to receive(:deploy)

      expect(described_class.run(pool: 'tank', name: 'rx')).to eq(status: true, output: nil)
      expect(key_chain).to have_received(:revoke_key).with('rx')
      expect(key_chain).to have_received(:save)
      expect(deployer).to have_received(:deploy)
    end
  end

  describe OsCtld::Commands::Send::KeyGen do
    it 'generates keys with the expected defaults and secures the outputs' do
      pools = stub_const('OsCtld::DB::Pools', Class.new do
        def self.find(_name); end
      end)
      key_chain = Struct.new(:private_key_path, :public_key_path).new('/keys/id', '/keys/id.pub')
      pool = Struct.new(:send_receive_key_chain, :name) do
        def pool
          self
        end
      end.new(key_chain, 'tank')
      allow(pools).to receive(:find).with('tank').and_return(pool)
      allow(FileUtils).to receive(:rm_f)
      allow(File).to receive(:chmod)
      allow(Socket).to receive(:gethostname).and_return('host1')
      command = described_class.new({ pool: 'tank', type: 'ecdsa' }, {})
      allow(command).to receive(:syscmd)

      expect(command.base_execute).to eq(status: true, output: nil)
      expect(command).to have_received(:syscmd).with(
        "ssh-keygen -q -t ecdsa -b 521 -N '' -C 'tank@host1' -f /keys/id"
      )
      expect(File).to have_received(:chmod).with(0o400, '/keys/id')
      expect(File).to have_received(:chmod).with(0o400, '/keys/id.pub')
    end
  end

  describe 'cpu scheduler commands' do
    before do
      scheduler = stub_const('OsCtld::CpuScheduler', Class.new do
        def self.disable; end

        def self.enable; end

        def self.disable_package(_pkg); end

        def self.enable_package(_pkg); end

        def self.export_packages; end

        def self.export_status; end

        def self.upkeep; end
      end)
      allow(scheduler).to receive(:disable)
      allow(scheduler).to receive(:enable)
      allow(scheduler).to receive_messages(disable_package: true, enable_package: false, export_packages: [{ package: 0, enabled: true }], export_status: { enabled: true })
      allow(scheduler).to receive(:upkeep)
    end

    it 'enables, disables, lists, and exports scheduler state' do
      expect(OsCtld::Commands::CpuScheduler::Disable.run).to eq(status: true, output: nil)
      expect(OsCtld::Commands::CpuScheduler::Enable.run).to eq(status: true, output: nil)
      expect(OsCtld::Commands::CpuScheduler::PackageList.run).to eq(
        status: true,
        output: [{ package: 0, enabled: true }]
      )
      expect(OsCtld::Commands::CpuScheduler::Status.run).to eq(
        status: true,
        output: { enabled: true }
      )
      expect(OsCtld::Commands::CpuScheduler::Upkeep.run).to eq(status: true, output: nil)
    end

    it 'maps package enable and disable return values to command results' do
      expect(OsCtld::Commands::CpuScheduler::PackageDisable.run(package: 0)).to eq(
        status: true,
        output: nil
      )
      expect(OsCtld::Commands::CpuScheduler::PackageEnable.run(package: 1)).to eq(
        status: false,
        message: 'package 1 not found'
      )
    end
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/VerifiedDoubles
