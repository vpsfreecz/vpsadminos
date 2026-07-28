# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/LeakyConstantDeclaration

require 'ostruct'
require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/dist_config'
require 'osctld/utils/container'
require 'osctld/utils/switch_user'
require 'osctld/commands/container/set'
require 'osctld/commands/container/unset'
require 'osctld/commands/container/config_reload'
require 'osctld/commands/container/config_replace'
require 'osctld/commands/container/set_image_config'
require 'osctld/commands/container/find_by_ugid'
require 'osctld/commands/container/list'
require 'osctld/commands/container/show'

RSpec.describe 'container configuration commands' do
  def build_history
    stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
  end

  def build_db_containers
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end

      def self.each; end

      def self.each_by_ids(_ids, _pool); end
    end)
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
    allow(build_history).to receive(:log)
  end

  describe OsCtld::Commands::Container::Set do
    it 'persists only changed and supported attributes' do
      ct = Struct.new(:autostart, :hostname, :changes, keyword_init: true) do
        def set(changes)
          self.changes = changes
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new(autostart: true, hostname: 'old', changes: nil)
      command = described_class.new(
        {
          autostart: true,
          hostname: 'new',
          seccomp_profile: 'default',
          ignored: 'value'
        },
        {}
      )

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.changes).to eq(hostname: 'new', seccomp_profile: 'default')
    end

    it 'logs persisted resolver intent when live application fails' do
      pool = Object.new
      ct = Struct.new(:dns_resolvers, :pool, keyword_init: true) do
        def set(_changes)
          raise OsCtld::DistConfig::ApplyError,
                'DNS resolver configuration was saved, but could not be applied'
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new(dns_resolvers: nil, pool:)
      opts = {
        id: 'ct1',
        pool: 'tank',
        dns_resolvers: ['192.0.2.53']
      }
      command = described_class.new(opts, {})

      expect(command.execute(ct)).to eq(
        status: false,
        message: 'DNS resolver configuration was saved, but could not be applied'
      )
      expect(OsCtld::History).to have_received(:log).with(pool, :ct_set, opts)
    end
  end

  describe OsCtld::Commands::Container::Unset do
    it 'passes through only supported unset attributes' do
      ct = Struct.new(:changes) do
        def unset(changes)
          self.changes = changes
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new(nil)
      command = described_class.new(
        {
          hostname: true,
          attrs: true,
          ignored: true
        },
        {}
      )

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.changes).to eq(hostname: true, attrs: true)
    end

    it 'logs persisted resolver removal when live clear fails' do
      pool = Object.new
      ct = Struct.new(:pool, keyword_init: true) do
        def unset(_changes)
          raise OsCtld::DistConfig::ApplyError,
                'DNS resolver configuration was cleared, but could not be applied'
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new(pool:)
      opts = {
        id: 'ct1',
        pool: 'tank',
        dns_resolvers: true
      }
      command = described_class.new(opts, {})

      expect(command.execute(ct)).to eq(
        status: false,
        message: 'DNS resolver configuration was cleared, but could not be applied'
      )
      expect(OsCtld::History).to have_received(:log).with(pool, :ct_unset, opts)
    end
  end

  describe OsCtld::Commands::Container::ConfigReload do
    it 'requires the container to be stopped' do
      ct = Struct.new(:current_state) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(:running)

      expect { described_class.new({}, {}).execute(ct) }
        .to raise_error(OsCtld::CommandFailed, 'the container has to be stopped')
    end

    it 'reloads configuration and regenerates lxc-usernet' do
      lxc_config = Struct.new do
        attr_reader :configured

        def configure
          @configured = true
        end
      end.new
      ct = Struct.new(:current_state, :lxc_config) do
        attr_reader :reloaded

        def reload_config
          @reloaded = true
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new(:stopped, lxc_config)
      usernet_class = stub_const('OsCtld::Commands::User::LxcUsernet', Class.new)
      command = described_class.new({}, {})
      allow(command).to receive(:call_cmd).with(usernet_class).and_return(status: true, output: nil)

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.reloaded).to be(true)
      expect(lxc_config.configured).to be(true)
    end
  end

  describe OsCtld::Commands::Container::ConfigReplace do
    it 'replaces configuration for stopped containers and regenerates lxc-usernet' do
      lxc_config = Struct.new do
        attr_reader :configured

        def configure
          @configured = true
        end
      end.new
      ct = Struct.new(:current_state, :lxc_config) do
        attr_reader :replaced

        def replace_config(config)
          @replaced = config
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new(:stopped, lxc_config)
      usernet_class = stub_const('OsCtld::Commands::User::LxcUsernet', Class.new)
      command = described_class.new({ config: { 'hostname' => 'ct1' } }, {})
      allow(command).to receive(:call_cmd).with(usernet_class).and_return(status: true, output: nil)

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.replaced).to eq('hostname' => 'ct1')
      expect(lxc_config.configured).to be(true)
    end
  end

  describe OsCtld::Commands::Container::SetImageConfig do
    def build_ct
      Struct.new(
        :pool,
        :id,
        :distribution,
        :version,
        :arch,
        :vendor,
        :variant,
        :patched_config,
        :set_calls,
        keyword_init: true
      ) do
        def running?
          false
        end

        def patch_config(cfg)
          self.patched_config = cfg
        end

        def set(changes)
          set_calls << changes
        end

        def manipulate(_holder, block:, &)
          yield
        end
      end.new(
        pool: Struct.new(:name).new('tank'),
        id: 'ct1',
        distribution: 'almalinux',
        version: '9',
        arch: 'x86_64',
        vendor: 'default',
        variant: 'default',
        patched_config: nil,
        set_calls: []
      )
    end

    it 'persists vendor-only metadata changes when applying image config' do
      with_tmpdir do |tmpdir|
        image_path = File.join(tmpdir, 'image.tar')
        File.write(image_path, 'image')
        importer_class = stub_const('OsCtld::Container::Importer', Class.new do
          def self.new(*); end
        end)
        importer = instance_double(
          importer_class,
          load_metadata: nil,
          get_container_config: { 'hostname' => 'from-image' }
        )
        allow(importer_class).to receive(:new).and_return(importer)
        ct = build_ct
        command = described_class.new(
          {
            type: 'image',
            path: image_path,
            image: { vendor: 'custom' }
          },
          {}
        )

        expect(command.execute(ct)).to eq(status: true, output: nil)
        expect(ct.patched_config).to eq('hostname' => 'from-image')
        expect(ct.set_calls).to eq(
          [
            {
              distribution: {
                name: 'almalinux',
                version: '9',
                arch: 'x86_64',
                vendor: 'custom',
                variant: 'default'
              }
            }
          ]
        )
      end
    end

    it 'fetches remote images with missing attributes filled from the container' do
      with_tmpdir do |tmpdir|
        image_path = File.join(tmpdir, 'image.tar')
        File.write(image_path, 'image')
        importer_class = stub_const('OsCtld::Container::Importer', Class.new do
          def self.new(*); end
        end)
        importer = instance_double(
          importer_class,
          load_metadata: nil,
          get_container_config: {}
        )
        allow(importer_class).to receive(:new).and_return(importer)
        ct = build_ct
        command = described_class.new(
          {
            type: 'remote',
            image: { version: '10' }
          },
          {}
        )
        allow(command).to receive(:with_image_path) do |pool, type:, path:, image:, &block|
          expect(pool).to eq(ct.pool)
          expect(type).to eq('remote')
          expect(path).to be_nil
          expect(image).to eq(
            distribution: 'almalinux',
            version: '10',
            arch: 'x86_64',
            vendor: 'default',
            variant: 'default'
          )
          block.call(image_path)
        end

        expect(command.execute(ct)).to eq(status: true, output: nil)
      end
    end
  end

  describe OsCtld::Commands::Container::FindByUgid do
    class FakeIdMap
      def initialize(entries)
        @entries = entries
      end

      def include_host_id?(id)
        @entries.has_key?(id)
      end

      def host_to_ns(id)
        @entries.fetch(id)
      end
    end

    it 'returns JSON-safe arrays keyed by uid and gid' do
      db = build_db_containers
      ct = Struct.new(:user) do
        def export
          { id: 'ct1' }
        end
      end.new(
        Struct.new(:uid_map, :gid_map).new(
          FakeIdMap.new(1000 => 0),
          FakeIdMap.new(2000 => 10)
        )
      )
      allow(db).to receive(:each).and_yield(ct)

      expect(described_class.run(uids: [1000], gids: [2000])).to eq(
        status: true,
        output: {
          by_uid: [[1000, [{ ns_id: 0, ct: { id: 'ct1' } }]]],
          by_gid: [[2000, [{ ns_id: 10, ct: { id: 'ct1' } }]]]
        }
      )
    end

    it 'rejects invalid ids' do
      expect { described_class.run(uids: [-1]) }
        .to raise_error(OsCtld::CommandFailed, '-1 is not a valid user/group ID')
    end
  end

  describe OsCtld::Commands::Container::List do
    class FakeExecutionPlan
      attr_reader :entries, :waited

      def initialize
        @entries = []
        @waited = false
      end

      def <<(entry)
        entries << entry
      end

      def empty?
        entries.empty?
      end

      def run(&block)
        entries.each do |ct, data|
          block.call(ct, data)
        end
      end

      def wait
        @waited = true
      end
    end

    def build_list_ct(id:, running:, ephemeral:, state:, hostname:)
      pool = Struct.new(:name).new('tank')
      user = Struct.new(:name).new('alice')
      group = Struct.new(:name).new('/default')
      Struct.new(
        :id,
        :pool,
        :user,
        :group,
        :distribution,
        :version,
        :arch,
        :vendor,
        :variant,
        :state,
        :ephemeral,
        :hostname
      ) do
        attr_accessor :read_hostname_calls

        def running?
          state == :running
        end

        def export
          { id:, state: state.to_s }
        end

        def read_hostname
          self.read_hostname_calls += 1
          hostname
        end
      end.new(
        id,
        pool,
        user,
        group,
        'almalinux',
        '9',
        'x86_64',
        'default',
        'default',
        state,
        ephemeral,
        hostname
      ).tap do |ct|
        ct.read_hostname_calls = 0
      end
    end

    it 'filters containers and reads hostnames only for running matches' do
      db = build_db_containers
      execution_plan = stub_const('OsCtld::ExecutionPlan', FakeExecutionPlan)
      running_ct = build_list_ct(id: 'ct1', running: true, ephemeral: false, state: :running, hostname: 'running.example')
      stopped_ct = build_list_ct(id: 'ct2', running: false, ephemeral: false, state: :stopped, hostname: 'stopped.example')
      skipped_ct = build_list_ct(id: 'ct3', running: true, ephemeral: true, state: :running, hostname: 'skip.example')
      allow(db).to receive(:each_by_ids).with(nil, ['tank']).and_yield(running_ct).and_yield(stopped_ct).and_yield(skipped_ct)

      expect(
        described_class.run(
          pool: ['tank'],
          ephemeral: false,
          read_hostname: true
        )
      ).to eq(
        status: true,
        output: [
          { id: 'ct1', state: 'running', hostname_readout: 'running.example' },
          { id: 'ct2', state: 'stopped', hostname_readout: nil }
        ]
      )
      expect(execution_plan).to be(FakeExecutionPlan)
      expect(running_ct.read_hostname_calls).to eq(1)
      expect(stopped_ct.read_hostname_calls).to eq(0)
    end
  end

  describe OsCtld::Commands::Container::Show do
    it 'returns exported container data and hostname readout when requested' do
      db = build_db_containers
      ct = Struct.new do
        def export
          { id: 'ct1' }
        end

        def read_hostname
          'ct1.example'
        end
      end.new
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(described_class.run(id: 'ct1', pool: 'tank', read_hostname: true)).to eq(
        status: true,
        output: { id: 'ct1', hostname_readout: 'ct1.example' }
      )
    end

    it 'raises when the container cannot be found' do
      db = build_db_containers
      allow(db).to receive(:find).with('ct1', 'tank').and_return(nil)

      expect { described_class.run(id: 'ct1', pool: 'tank') }
        .to raise_error(OsCtld::CommandFailed, 'container not found')
    end
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/LeakyConstantDeclaration
