# frozen_string_literal: true

require 'osctld/attributes'
require 'osctld/group'

RSpec.describe OsCtld::Group do
  let(:cgparams_class) do
    Class.new do
      attr_reader :owner, :cfg

      def self.load(owner, cfg)
        new(owner, cfg:)
      end

      def initialize(owner, cfg: nil)
        @owner = owner
        @cfg = cfg
        @memory = nil
        @swap = nil
        @cpu = nil
      end

      attr_writer :memory, :swap, :cpu

      def find_memory_limit = @memory
      def find_swap_limit = @swap
      def find_cpu_limit = @cpu
      def dump = cfg || { 'fake' => true }
    end
  end

  let(:devices_class) do
    Class.new do
      attr_reader :owner, :cfg

      def self.new_for(owner)
        new(owner, cfg: nil)
      end

      def self.load(owner, cfg)
        new(owner, cfg:)
      end

      def initialize(owner, cfg: nil)
        @owner = owner
        @cfg = cfg
      end

      def init; end
      def dump = cfg || []
      def assets(_add); end
    end
  end

  def build_group(pool, name, load: false, root: false, devices: false)
    described_class.new(pool, name, load:, root:, devices:)
  end

  before do
    allow(File).to receive(:chown).and_return(0)
    stub_const('OsCtld::CGroup::Params', cgparams_class)
    stub_const('OsCtld::Devices::Manager', devices_class)
  end

  it 'identifies root groups and builds config paths' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      root = build_group(pool, '/', root: true)
      child = build_group(pool, '/app')

      expect(root).to be_root
      expect(root.ident).to eq('tank:/')
      expect(root.config_dir).to eq(File.join(pool.conf_path, 'group', '/'))
      expect(root.config_path).to eq(File.join(pool.conf_path, 'group', '/', 'config.yml'))
      expect(child.root?).to be(false)
      expect(child.config_path).to eq(File.join(pool.conf_path, 'group', '/app', 'config.yml'))
    end
  end

  it 'builds paths and user directories for root and child groups' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      root = build_group(pool, '/', root: true)
      child = build_group(pool, '/app')
      user = FakeObjects::FakeUser.new(name: 'alice', userdir: '/run/users/alice')

      root.configure(path: '/osctl/pool.tank', devices: false)
      child.configure(devices: false)
      stub_groups_registry([root, child], root: root)

      expect(root.path).to eq('/osctl/pool.tank')
      expect(child.path).to eq('/osctl/pool.tank/app')
      expect(root.cgroup_path).to eq('/osctl/pool.tank')
      expect(child.cgroup_path).to eq('/osctl/pool.tank/group.app')
      expect(root.userdir(user)).to eq('/run/users/alice/cts')
      expect(child.userdir(user)).to eq('/run/users/alice/group.app/cts')
    end
  end

  it 'finds parents and groups in the current path' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      root = build_group(pool, '/', root: true)
      child = build_group(pool, '/app')
      grandchild = build_group(pool, '/app/db')

      root.configure(path: '/osctl/pool.tank', devices: false)
      child.configure(devices: false)
      grandchild.configure(devices: false)
      stub_groups_registry([root, child, grandchild], root: root)

      expect(grandchild.parents).to eq([root, child])
      expect(grandchild.parent).to eq(child)
      expect(grandchild.groups_in_path).to eq([root, child, grandchild])
    end
  end

  it 'enumerates child and descendant groups' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      root = build_group(pool, '/', root: true)
      app = build_group(pool, '/app')
      db = build_group(pool, '/app/db')
      svc = build_group(pool, '/svc')

      root.configure(path: '/osctl/pool.tank', devices: false)
      app.configure(devices: false)
      db.configure(devices: false)
      svc.configure(devices: false)
      stub_groups_registry([root, app, db, svc], root: root)

      expect(root.children).to eq([app, svc])
      expect(root.descendants).to eq([app, db, svc])
      expect(app.children).to eq([db])
      expect(app.descendants).to eq([db])
    end
  end

  it 'filters direct containers and users for the group' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      root = build_group(pool, '/', root: true)
      child = build_group(pool, '/app')
      nested = build_group(pool, '/app/db')
      alice = FakeObjects::FakeNamed.new('alice')
      bob = FakeObjects::FakeNamed.new('bob')

      root.configure(path: '/osctl/pool.tank', devices: false)
      child.configure(devices: false)
      nested.configure(devices: false)
      stub_groups_registry([root, child, nested], root: root)

      ct1 = FakeObjects::FakeContainer.new(id: 'ct1', pool:, group: child, user: alice)
      ct2 = FakeObjects::FakeContainer.new(id: 'ct2', pool:, group: child, user: bob)
      ct3 = FakeObjects::FakeContainer.new(id: 'ct3', pool:, group: nested, user: alice)
      stub_containers_registry([ct1, ct2, ct3])

      expect(child.has_containers?).to be(true)
      expect(child.has_containers?(alice)).to be(true)
      expect(child.has_containers?(FakeObjects::FakeNamed.new('carol'))).to be(false)
      expect(child.containers).to eq([ct1, ct2])
      expect(child.users).to eq([alice, bob])
    end
  end

  it 'returns true when a container in a descendant group is running' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      root = build_group(pool, '/', root: true)
      child = build_group(pool, '/app')

      root.configure(path: '/osctl/pool.tank', devices: false)
      child.configure(devices: false)
      stub_groups_registry([root, child], root: root)

      ct = FakeObjects::FakeContainer.new(
        id: 'ct1',
        pool: pool,
        group: child,
        user: FakeObjects::FakeNamed.new('alice'),
        running: true
      )
      stub_containers_registry([ct])

      expect(root.any_container_running?).to be(true)
    end
  end

  it 'uses local limits and falls back to a parent when needed' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      root = build_group(pool, '/', root: true)
      child = build_group(pool, '/app')

      root.configure(path: '/osctl/pool.tank', devices: false)
      child.configure(devices: false)
      stub_groups_registry([root, child], root: root)

      root.cgparams.memory = 1024
      root.cgparams.swap = 2048
      root.cgparams.cpu = 300
      child.cgparams.memory = 512

      expect(child.find_memory_limit(parents: false)).to eq(512)
      expect(child.find_memory_limit).to eq(512)
      expect(child.find_swap_limit).to eq(2048)
      expect(child.find_cpu_limit).to eq(300)
    end
  end

  it 'updates and removes custom attributes' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      group = build_group(pool, '/app')

      group.configure(devices: false)
      group.set(attrs: { 'org.vpsfree.cz/test:role' => 'system' })
      expect(group.attrs['org.vpsfree.cz/test:role']).to eq('system')

      group.unset(attrs: ['org.vpsfree.cz/test:role'])

      expect(group.attrs.dump).to eq({})
    end
  end

  it 'round-trips cgparams, devices, attrs, and root path through config' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      root = build_group(pool, '/', root: true)

      root.configure(path: '/osctl/pool.tank', devices: false)
      root.set(attrs: { 'org.vpsfree.cz/test:role' => 'root' })

      reloaded = described_class.new(pool, '/', root: true, devices: false)

      expect(reloaded.path).to eq('/osctl/pool.tank')
      expect(reloaded.cgparams.dump).to eq('fake' => true)
      expect(reloaded.devices.dump).to eq([])
      expect(reloaded.attrs['org.vpsfree.cz/test:role']).to eq('root')
    end
  end
end
