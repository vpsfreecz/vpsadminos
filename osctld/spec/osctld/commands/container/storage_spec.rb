# frozen_string_literal: true

# rubocop:disable Lint/StructNewOverride, Lint/UnusedBlockArgument, RSpec/DescribeClass, RSpec/InstanceVariable

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/switch_user'
require 'osctld/utils/assets'
require 'osctld/utils/switch_user'

module OsCtld
  module Commands
    module Dataset; end
  end
end

require 'osctld/commands/container/assets'
require 'osctld/commands/container/mount'
require 'osctld/commands/container/mount_activate'
require 'osctld/commands/container/mount_clear'
require 'osctld/commands/container/mount_create'
require 'osctld/commands/container/mount_dataset'
require 'osctld/commands/container/mount_deactivate'
require 'osctld/commands/container/mount_delete'
require 'osctld/commands/container/mount_list'
require 'osctld/commands/container/mount_register'
require 'osctld/commands/dataset/create'
require 'osctld/commands/dataset/delete'
require 'osctld/commands/dataset/list'

RSpec.describe 'container storage commands' do
  def build_history
    stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
  end

  def build_db_containers
    stub_const('OsCtld::DB::Containers', Class.new do
      def self.find(_id, _pool); end
    end)
  end

  def build_ct(dataset_name: 'tank/ct1', runtime_state: :stopped)
    dataset = Struct.new(:name).new(dataset_name)
    Struct.new(:dataset, :runtime_state) do
      attr_accessor :mounts, :run_conf

      def current_runtime_state
        runtime_state
      end

      def manipulate(_holder, block:, &)
        yield
      end

      def inclusively(&block)
        block.call
      end

      def mount(force: false)
        @mount_calls ||= []
        @mount_calls << force
      end

      def mount_calls
        @mount_calls ||= []
      end
    end.new(dataset, runtime_state)
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
    allow(build_history).to receive(:log)
  end

  describe OsCtld::Commands::Container::Assets do
    it 'returns validated assets from the resolved container' do
      db = build_db_containers
      ct = build_ct
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      command = described_class.new({ id: 'ct1', pool: 'tank' }, {})
      allow(command).to receive(:list_and_validate_assets).with(ct).and_return([{ path: '/tmp/x' }])

      expect(command.execute).to eq(status: true, output: [{ path: '/tmp/x' }])
    end
  end

  describe OsCtld::Commands::Container::Mount do
    it 'forces a container mount through manipulate' do
      db = build_db_containers
      ct = build_ct
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(described_class.new({ id: 'ct1', pool: 'tank' }, {}).execute).to eq(status: true, output: nil)
      expect(ct.mount_calls).to eq([true])
    end
  end

  describe OsCtld::Commands::Container::MountCreate do
    before do
      mount_entry = stub_const('OsCtld::Mount::Entry', Class.new do
        attr_reader :mountpoint

        def initialize(_fs, mountpoint, *_args, **_kwargs)
          @mountpoint = mountpoint
        end
      end)
      allow(mount_entry).to receive(:new).and_call_original
    end

    it 'rejects duplicate mountpoints' do
      ct = build_ct
      ct.mounts = Struct.new do
        def find_at(path)
          path == '/mnt/data' ? Object.new : nil
        end
      end.new
      command = described_class.new({ fs: '/src', mountpoint: '/mnt/data', type: 'bind', opts: 'bind', automount: true }, {})

      expect(command.execute(ct)).to eq(
        status: false,
        message: "mountpoint '/mnt/data' is already mounted"
      )
    end

    it 'adds new mount entries' do
      ct = build_ct
      ct.mounts = Struct.new(:added) do
        def find_at(_path)
          nil
        end

        def add(mnt)
          added << mnt.mountpoint
        end
      end.new([])
      command = described_class.new({ fs: '/src', mountpoint: '/mnt/data', type: 'bind', opts: 'bind', automount: true, map_ids: true }, {})

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.mounts.added).to eq(['/mnt/data'])
    end
  end

  describe OsCtld::Commands::Container::MountDataset do
    before do
      mount_entry = stub_const('OsCtld::Mount::Entry', Class.new do
        attr_reader :mountpoint, :dataset

        def initialize(_fs, mountpoint, *_args, dataset:, **_kwargs)
          @mountpoint = mountpoint
          @dataset = dataset
        end
      end)
      dataset_class = stub_const('OsCtl::Lib::Zfs::Dataset', Class.new do
        def self.new(*); end
      end)
      allow(mount_entry).to receive(:new).and_call_original
      allow(dataset_class).to receive(:new) do |name, base:|
        Struct.new(:name) do
          def exist?
            true
          end
        end.new(name)
      end
    end

    it 'errors when the dataset does not exist' do
      ct = build_ct
      ct.mounts = Struct.new do
        def find_at(_path)
          nil
        end
      end.new
      allow(OsCtl::Lib::Zfs::Dataset).to receive(:new).and_return(
        Struct.new(:name) do
          def exist?
            false
          end
        end.new('tank/ct1/data')
      )
      command = described_class.new({ name: 'data', mountpoint: '/mnt/data', mode: 'rw', automount: true }, {})

      expect { command.execute(ct) }
        .to raise_error(OsCtld::CommandFailed, 'dataset tank/ct1/data does not exist')
    end

    it 'adds dataset-backed mounts' do
      ct = build_ct
      ct.mounts = Struct.new(:added) do
        def find_at(_path)
          nil
        end

        def add(mnt)
          added << [mnt.mountpoint, mnt.dataset.name]
        end
      end.new([])
      command = described_class.new({ name: 'data', mountpoint: '/mnt/data', mode: 'rw', automount: true }, {})

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.mounts.added).to eq([['/mnt/data', 'tank/ct1/data']])
    end
  end

  describe OsCtld::Commands::Container::MountActivate do
    it 'requires the container to be running' do
      ct = build_ct(runtime_state: :stopped)
      ct.mounts = Struct.new do
        def activate(_mountpoint); end
      end.new

      expect { described_class.new({ mountpoint: '/mnt/data' }, {}).execute(ct) }
        .to raise_error(OsCtld::CommandFailed, 'the container has to be running')
    end

    it 'maps missing mounts to command failures' do
      ct = build_ct(runtime_state: :running)
      ct.mounts = Struct.new do
        def activate(_mountpoint)
          raise OsCtld::MountNotFound
        end
      end.new

      expect { described_class.new({ mountpoint: '/mnt/data' }, {}).execute(ct) }
        .to raise_error(OsCtld::CommandFailed, 'mount not found')
    end
  end

  describe OsCtld::Commands::Container::MountClear do
    it 'maps unmount errors to command failures' do
      ct = build_ct
      ct.mounts = Struct.new do
        def clear
          raise OsCtld::UnmountError, 'busy'
        end
      end.new

      expect(described_class.new({}, {}).execute(ct)).to eq(
        status: false,
        message: 'unable to unmount directory from the container: busy'
      )
    end
  end

  describe OsCtld::Commands::Container::MountDelete do
    it 'maps unmount errors when deleting mount registrations' do
      ct = build_ct
      ct.mounts = Struct.new do
        def delete_at(_mountpoint)
          raise OsCtld::UnmountError
        end
      end.new

      expect(described_class.new({ mountpoint: '/mnt/data' }, {}).execute(ct)).to eq(
        status: false,
        message: 'unable to unmount the directory from the container'
      )
    end
  end

  describe OsCtld::Commands::Container::MountList do
    it 'exports registered mounts' do
      db = build_db_containers
      ct = build_ct
      mount = Struct.new do
        def export
          { mountpoint: '/mnt/data' }
        end
      end.new
      ct.mounts = [mount]
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(described_class.new({ id: 'ct1', pool: 'tank' }, {}).execute).to eq(
        status: true,
        output: [{ mountpoint: '/mnt/data' }]
      )
    end
  end

  describe OsCtld::Commands::Container::MountRegister do
    before do
      mount_entry = stub_const('OsCtld::Mount::Entry', Class.new do
        attr_reader :mountpoint

        def initialize(_fs, mountpoint, *_args, **_kwargs)
          @mountpoint = mountpoint
        end
      end)
      allow(mount_entry).to receive(:new).and_call_original
    end

    it 'registers temporary mounts without taking the lock when lock is false' do
      ct = build_ct
      ct.mounts = Struct.new(:registered) do
        def find_at(_path)
          nil
        end

        def register(mnt)
          registered << mnt.mountpoint
        end
      end.new([])
      command = described_class.new({ fs: '/src', mountpoint: '/mnt/data', type: 'bind', lock: false }, {})
      allow(command).to receive(:manipulate)

      expect(command.execute(ct)).to eq(status: true, output: nil)
      expect(ct.mounts.registered).to eq(['/mnt/data'])
      expect(command).not_to have_received(:manipulate)
    end
  end

  describe OsCtld::Commands::Dataset::Create do
    it 'creates missing datasets and mounts the target through mount_dataset' do
      db = build_db_containers
      parent = Struct.new(:name, :exist, :created, :mounted, :private_created, :base_name, :relative_name, :parent_obj) do
        def exist?
          exist
        end

        def create!(properties:)
          self.created = properties
        end

        def mount
          self.mounted = true
        end

        def create_private!
          self.private_created = true
        end

        def parent
          parent_obj
        end
      end.new('tank/ct1/data', false, nil, false, false, 'data', 'data', Struct.new(:root?) { def name = 'tank/ct1' }.new(true))
      wanted = Struct.new(:name, :relative_parents, :exist, :created, :mounted, :private_created, :base_name, :relative_name, :parent_obj) do
        def exist?
          exist
        end

        def create!(properties:)
          self.created = properties
        end

        def mount
          self.mounted = true
        end

        def create_private!
          self.private_created = true
        end

        def parent
          parent_obj
        end
      end.new('tank/ct1/data/logs', [parent], false, nil, false, false, 'logs', 'data/logs', parent)
      dataset_class = stub_const('OsCtl::Lib::Zfs::Dataset', Class.new do
        def self.new(*); end
      end)
      allow(dataset_class).to receive(:new).and_return(wanted)
      ct = Struct.new(:dataset, :map_mode, :uid_map, :gid_map, :mounts, :id, :pool) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(
        Struct.new(:name).new('tank/ct1'),
        'zfs',
        [Struct.new(:to_s).new('0:100000:65536')],
        [Struct.new(:to_s).new('0:100000:65536')],
        [],
        'ct1',
        Struct.new(:name).new('tank')
      )
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      command = described_class.new({ id: 'ct1', pool: 'tank', name: 'data/logs', mount: true }, {})
      allow(command).to receive(:call_cmd!).with(
        OsCtld::Commands::Container::MountDataset,
        id: 'ct1',
        pool: 'tank',
        name: 'data/logs',
        mountpoint: '/logs',
        mode: 'rw',
        automount: true
      ).and_return(status: true, output: nil)
      allow(command).to receive(:parent_mountpoint) do |_target_ct, ds|
        ds.equal?(wanted) ? '/' : nil
      end

      expect(command.execute).to eq(status: true, output: nil)
      expect(parent.created).to include(canmount: 'noauto')
      expect(parent.created[:uidmap]).to eq('0:100000:65536')
      expect(wanted.created[:gidmap]).to eq('0:100000:65536')
    end
  end

  describe OsCtld::Commands::Dataset::Delete do
    it 'rejects root dataset deletion' do
      db = build_db_containers
      allow(db).to receive(:find).with('ct1', 'tank').and_return(build_ct)

      expect(described_class.run(name: '/', id: 'ct1', pool: 'tank')).to eq(
        status: false,
        message: 'cannot delete the root dataset'
      )
    end

    it 'requires recursive deletion when descendants exist' do
      db = build_db_containers
      dataset_class = stub_const('OsCtl::Lib::Zfs::Dataset', Class.new do
        def self.new(*); end
      end)
      ds = Struct.new(:name) do
        def exist?
          true
        end

        def descendants
          [Struct.new(:relative_name).new('data/logs')]
        end
      end.new('tank/ct1/data')
      allow(dataset_class).to receive(:new).and_return(ds)
      ct = build_ct
      ct.mounts = []
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect { described_class.new({ id: 'ct1', pool: 'tank', name: 'data' }, {}).execute }
        .to raise_error(
          OsCtld::CommandFailed,
          'dataset has children, recursive delete has to be enabled explicitly'
        )
    end
  end

  describe OsCtld::Commands::Dataset::List do
    it 'exports datasets from the resolved container' do
      db = build_db_containers
      dataset = Struct.new do
        def list(properties:)
          [Struct.new do
            def export
              { name: 'tank/ct1/data' }
            end
          end.new]
        end
      end.new
      ct = build_ct
      ct.dataset = dataset
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(described_class.new({ id: 'ct1', pool: 'tank', properties: %w[canmount] }, {}).execute).to eq(
        status: true,
        output: [{ name: 'tank/ct1/data' }]
      )
    end
  end
end

# rubocop:enable Lint/StructNewOverride, Lint/UnusedBlockArgument, RSpec/DescribeClass, RSpec/InstanceVariable
