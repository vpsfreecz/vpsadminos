# frozen_string_literal: true

require 'osctld/attributes'
require 'osctld/id_map'
require 'osctld/user'

RSpec.describe OsCtld::User do
  def build_user(root:, name: 'alice', load: false)
    pool = build_fake_pool(root: root)
    prepare_pool_conf_dirs(pool, 'user')

    [pool, described_class.new(pool, name, load: load)]
  end

  def build_id_map
    OsCtld::IdMap.load(['0:100000:65536'])
  end

  before do
    allow(File).to receive(:chown).and_return(0)

    stub_const('OsCtld::SystemUsers', Object.new.tap do |obj|
      obj.define_singleton_method(:uid_of) { |_name| nil }
      obj.define_singleton_method(:include?) { |_name| false }
    end)

    stub_const('OsCtld::UGidRegistry', Object.new.tap do |obj|
      obj.define_singleton_method(:get) { 200_000 }
    end)
  end

  it 'persists UID and GID maps together with standalone mode' do
    with_tmpdir do |dir|
      _pool, user = build_user(root: dir)

      user.configure(build_id_map, build_id_map, standalone: false)

      expect(user.ugid).to eq(200_000)
      expect(load_yaml_file(user.config_path)).to eq(
        'uid_map' => ['0:100000:65536'],
        'gid_map' => ['0:100000:65536'],
        'standalone' => false,
        'attrs' => {}
      )
    end
  end

  it 'respects an explicit ugid during configure' do
    with_tmpdir do |dir|
      _pool, user = build_user(root: dir)

      user.configure(build_id_map, build_id_map, ugid: 1234, standalone: true)

      expect(user.ugid).to eq(1234)
    end
  end

  it 'loads maps, standalone mode, and attrs from a config string' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      config = dump_yaml(
        'uid_map' => ['0:100000:65536'],
        'gid_map' => ['0:200000:65536'],
        'standalone' => false,
        'attrs' => { 'org.vpsfree.cz/test:role' => 'system' }
      )

      user = described_class.new(pool, 'alice', config:)

      expect(user.ugid).to eq(200_000)
      expect(user.uid_map.dump).to eq(['0:100000:65536'])
      expect(user.gid_map.dump).to eq(['0:200000:65536'])
      expect(user.standalone).to be(false)
      expect(user.attrs['org.vpsfree.cz/test:role']).to eq('system')
    end
  end

  it 'defaults standalone to true when the key is missing' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      config = dump_yaml(
        'uid_map' => ['0:100000:65536'],
        'gid_map' => ['0:100000:65536']
      )

      user = described_class.new(pool, 'alice', config:)

      expect(user.standalone).to be(true)
    end
  end

  it 'toggles standalone mode through set and unset' do
    with_tmpdir do |dir|
      pool, user = build_user(root: dir)
      user.configure(build_id_map, build_id_map, standalone: false)

      user.set(standalone: true)
      expect(user.standalone).to be(true)
      expect(load_yaml_file(user.config_path)['standalone']).to be(true)

      user.unset(standalone: true)
      expect(user.standalone).to be(false)
      expect(load_yaml_file(user.config_path)['standalone']).to be(false)

      reloaded = described_class.new(pool, 'alice')
      expect(reloaded.standalone).to be(false)
    end
  end

  it 'updates and removes custom attributes' do
    with_tmpdir do |dir|
      pool, user = build_user(root: dir)
      user.configure(build_id_map, build_id_map)

      user.set(attrs: { 'org.vpsfree.cz/test:role' => 'system' })
      expect(user.attrs['org.vpsfree.cz/test:role']).to eq('system')

      user.unset(attrs: ['org.vpsfree.cz/test:role'])
      reloaded = described_class.new(pool, 'alice')

      expect(reloaded.attrs.dump).to eq({})
    end
  end

  it 'builds helper paths and system names from the pool and user name' do
    with_tmpdir do |dir|
      _pool, user = build_user(root: dir)
      user.configure(build_id_map, build_id_map, ugid: 1234)

      expect(user.sysusername).to eq('tank-alice')
      expect(user.sysgroupname).to eq('tank-alice')
      expect(user.userdir).to eq(File.join(dir, 'run', 'users', 'alice'))
      expect(user.homedir).to eq(File.join(dir, 'run', 'users', 'alice', '.home'))
      expect(user.config_path).to eq(File.join(dir, 'conf', 'user', 'alice.yml'))
    end
  end

  it 'finds only containers belonging to the user in the same pool' do
    with_tmpdir do |dir|
      pool, user = build_user(root: dir)
      user.configure(build_id_map, build_id_map, ugid: 1234, standalone: true)

      same = FakeObjects::FakeContainer.new(
        id: 'ct1',
        pool: pool,
        group: FakeObjects::FakeNamed.new('/default'),
        user: user,
        running: false
      )

      other_user = FakeObjects::FakeNamed.new('bob')
      other_pool = build_fake_pool(root: File.join(dir, 'other'), name: 'pool2')

      different_user = FakeObjects::FakeContainer.new(
        id: 'ct2',
        pool: pool,
        group: FakeObjects::FakeNamed.new('/default'),
        user: other_user,
        running: false
      )

      different_pool = FakeObjects::FakeContainer.new(
        id: 'ct3',
        pool: other_pool,
        group: FakeObjects::FakeNamed.new('/default'),
        user: user,
        running: false
      )

      stub_containers_registry([same, different_user, different_pool])

      expect(user.has_containers?).to be(true)
      expect(user.containers).to eq([same])
    end
  end

  it 'memoizes registration checks against system users' do
    with_tmpdir do |dir|
      _pool, user = build_user(root: dir)
      user.configure(build_id_map, build_id_map)

      allow(OsCtld::SystemUsers).to receive(:include?).with('tank-alice').and_return(true)

      expect(user.registered?).to be(true)
      expect(user.registered?).to be(true)
      expect(OsCtld::SystemUsers).to have_received(:include?).once
    end
  end
end
