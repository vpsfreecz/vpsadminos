# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, Lint/StructNewOverride, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/LeakyConstantDeclaration

require 'osctld/command'
require 'osctld/exceptions'
require 'osctld/utils/switch_user'

module OsCtld
  module Commands
    module Dataset; end
    module Container; end
  end
end

require 'osctld/commands/dataset/create'
require 'osctld/commands/dataset/delete'
require 'osctld/commands/dataset/list'

RSpec.describe 'dataset commands' do
  class FakeMounts
    include Enumerable

    attr_reader :deleted

    def initialize(items)
      @items = items
      @deleted = []
    end

    def each(&block)
      @items.each(&block)
    end

    def detect(&block)
      @items.detect(&block)
    end

    def select(&block)
      @items.select(&block)
    end

    def delete_at(mountpoint)
      @deleted << mountpoint
      @items.reject! { |mnt| mnt.mountpoint == mountpoint }
    end
  end

  class RootDataset
    def root?
      true
    end
  end

  class FakeZfsDataset
    attr_accessor :parent, :relative_parents, :descendants, :listed, :exists
    attr_reader :name, :base_name, :relative_name, :created_properties, :destroy_recursive

    def initialize(name:, base_name:, relative_name:, parent:, relative_parents: [], descendants: [], listed: [], exists: false)
      @name = name
      @base_name = base_name
      @relative_name = relative_name
      @parent = parent
      @relative_parents = relative_parents
      @descendants = descendants
      @listed = listed
      @exists = exists
      @created_properties = nil
      @destroy_recursive = nil
    end

    def exist?
      exists
    end

    def create!(properties:)
      @created_properties = properties
    end

    def mount; end

    def create_private!; end

    def list(properties:)
      @list_properties = properties
      listed
    end

    def destroy!(recursive:)
      @destroy_recursive = recursive
    end

    def root?
      false
    end
  end

  def build_ct(
    dataset:, mounts: FakeMounts.new([]), runtime_state: :stopped,
    map_mode: 'native'
  )
    uid_entry = Struct.new(:to_s).new('0:100000:65536')
    gid_entry = Struct.new(:to_s).new('0:200000:65536')

    Struct.new(
      :id, :pool, :dataset, :mounts, :runtime_state, :run_conf, :map_mode,
      :uid_map, :gid_map,
      keyword_init: true
    ) do
      def manipulate(_holder, block:, &)
        yield
      end

      def inclusively
        yield
      end
    end.new(
      id: 'ct1',
      pool: Struct.new(:name).new('tank'),
      dataset:,
      mounts:,
      runtime_state:,
      run_conf: Struct.new(:runtime_rootfs).new('/runtime'),
      map_mode:,
      uid_map: [uid_entry],
      gid_map: [gid_entry]
    )
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  describe OsCtld::Commands::Dataset::List do
    it 'lists exported datasets for the selected container' do
      row = Struct.new(:export).new({ name: 'data' })
      dataset = Class.new do
        def list(*); end
      end.new
      allow(dataset).to receive(:list).with(properties: %w[name used]).and_return([row])
      ct = build_ct(dataset:)
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(described_class.run(id: 'ct1', pool: 'tank', properties: %w[name used])).to eq(
        status: true,
        output: [{ name: 'data' }]
      )
      expect(dataset).to have_received(:list).with(properties: %w[name used])
    end
  end

  describe OsCtld::Commands::Dataset::Create do
    it 'creates missing parent datasets, preserves zfs mappings, and mounts the target' do
      mount_dataset = stub_const('OsCtld::Commands::Container::MountDataset', Class.new)
      root = RootDataset.new
      parent = FakeZfsDataset.new(
        name: 'tank/ct1/data',
        base_name: 'data',
        relative_name: 'data',
        parent: root
      )
      wanted = FakeZfsDataset.new(
        name: 'tank/ct1/data/sub',
        base_name: 'sub',
        relative_name: 'data/sub',
        parent: parent,
        relative_parents: [parent]
      )
      ct_root = Struct.new(:name).new('tank/ct1')
      ct = build_ct(dataset: ct_root, map_mode: 'zfs')
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(OsCtl::Lib::Zfs::Dataset).to receive(:new)
        .with('tank/ct1/data/sub', base: 'tank/ct1')
        .and_return(wanted)

      command = described_class.new(
        { id: 'ct1', pool: 'tank', name: 'data/sub', mount: true, mountpoint: '/srv/data' },
        {}
      )
      allow(command).to receive(:call_cmd!).with(
        mount_dataset,
        id: 'ct1',
        pool: 'tank',
        name: 'data',
        mountpoint: '/data',
        mode: 'rw',
        automount: true
      ).and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!).with(
        mount_dataset,
        id: 'ct1',
        pool: 'tank',
        name: 'data/sub',
        mountpoint: '/srv/data',
        mode: 'rw',
        automount: true
      ).and_return(status: true, output: nil)

      expect(command.execute).to eq(status: true, output: nil)
      expect(parent.created_properties).to eq(
        canmount: 'noauto',
        uidmap: '0:100000:65536',
        gidmap: '0:200000:65536'
      )
      expect(wanted.created_properties).to eq(
        canmount: 'noauto',
        uidmap: '0:100000:65536',
        gidmap: '0:200000:65536'
      )
    end
  end

  describe OsCtld::Commands::Dataset::Delete do
    it 'rejects deleting the root dataset' do
      ct = build_ct(dataset: Struct.new(:name).new('tank/ct1'))
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)

      expect(described_class.run(id: 'ct1', pool: 'tank', name: '/')).to eq(
        status: false,
        message: 'cannot delete the root dataset'
      )
    end

    it 'recursively unmounts matching datasets before destruction' do
      child = FakeZfsDataset.new(
        name: 'tank/ct1/data/sub',
        base_name: 'sub',
        relative_name: 'data/sub',
        parent: nil
      )
      dataset = FakeZfsDataset.new(
        name: 'tank/ct1/data',
        base_name: 'data',
        relative_name: 'data',
        parent: nil,
        descendants: [child],
        exists: true
      )
      mounts = FakeMounts.new([
                                Struct.new(:dataset, :mountpoint).new(dataset, 'data'),
                                Struct.new(:dataset, :mountpoint).new(child, 'data/sub')
                              ])
      ct = build_ct(
        dataset: Struct.new(:name).new('tank/ct1'),
        mounts:,
        runtime_state: :running
      )
      db = stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      allow(db).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(OsCtl::Lib::Zfs::Dataset).to receive(:new)
        .with('tank/ct1/data', base: 'tank/ct1')
        .and_return(dataset)
      allow(Dir).to receive(:exist?).and_return(true)

      command = described_class.new(
        { id: 'ct1', pool: 'tank', name: 'data', recursive: true, unmount: true },
        {}
      )
      allow(command).to receive(:ct_syscmd).and_return(
        Struct.new(:exitstatus, :output).new(0, '')
      )

      expect(command.execute).to eq(status: true, output: nil)
      expect(command).to have_received(:ct_syscmd).with(
        ct,
        ['umount', '/data/sub'],
        valid_rcs: [1]
      )
      expect(command).to have_received(:ct_syscmd).with(
        ct,
        ['umount', '/data'],
        valid_rcs: [1]
      )
      expect(mounts.deleted).to eq(%w[data/sub data])
      expect(dataset.destroy_recursive).to be(true)
    end
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock, Lint/StructNewOverride, RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/LeakyConstantDeclaration
