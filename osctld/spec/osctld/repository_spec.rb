# frozen_string_literal: true

require 'osctld/attributes'
require 'osctld/repository'

RSpec.describe OsCtld::Repository do
  def build_repository(root:, name: 'default')
    pool = build_fake_pool(root: root)
    prepare_pool_conf_dirs(pool, 'repository')

    [pool, described_class.new(pool, name, load: false)]
  end

  before do
    allow(File).to receive(:chown).and_return(0)
  end

  it 'starts enabled and exposes helper paths' do
    with_tmpdir do |dir|
      pool, repository = build_repository(root: dir)

      expect(repository).to be_enabled
      expect(repository).not_to be_disabled
      expect(repository.ident).to eq('tank:default')
      expect(repository.config_path).to eq(File.join(pool.conf_path, 'repository', 'default.yml'))
      expect(repository.cache_path).to eq(File.join(pool.repo_path, 'default'))
      expect(repository.cache_lock_path).to eq(File.join(pool.repo_path, 'default', '.osctld-cache.lock'))
      expect(repository.manipulation_resource).to eq(['repository', 'tank:default'])
    end
  end

  it 'persists repository configuration and reloads it' do
    with_tmpdir do |dir|
      pool, repository = build_repository(root: dir)

      repository.configure(
        'https://example.invalid/repo',
        prune_enabled: false,
        prune_interval: 60,
        prune_older_than_days: 7
      )
      repository.set(attrs: { 'org.vpsfree.cz/test:role' => 'mirror' })

      reloaded = described_class.new(pool, 'default')

      expect(reloaded.url).to eq('https://example.invalid/repo')
      expect(reloaded.prune_enabled).to be(false)
      expect(reloaded.prune_interval).to eq(60)
      expect(reloaded.prune_older_than_days).to eq(7)
      expect(reloaded.attrs['org.vpsfree.cz/test:role']).to eq('mirror')
    end
  end

  it 'enables and disables the repository' do
    with_tmpdir do |dir|
      pool, repository = build_repository(root: dir)
      repository.configure('https://example.invalid/repo')

      repository.disable
      expect(repository).to be_disabled
      expect(load_yaml_file(repository.config_path)['enabled']).to be(false)

      repository.enable
      expect(repository).to be_enabled
      expect(described_class.new(pool, 'default')).to be_enabled
    end
  end

  it 'updates settings and attrs through set' do
    with_tmpdir do |dir|
      _pool, repository = build_repository(root: dir)
      repository.configure('https://example.invalid/repo', prune_enabled: false)

      allow(repository).to receive(:start_prune)

      repository.set(
        url: 'https://example.invalid/other',
        prune_enabled: true,
        prune_interval: 120,
        prune_older_than_days: 30,
        attrs: { 'org.vpsfree.cz/test:role' => 'mirror' }
      )

      expect(repository.url).to eq('https://example.invalid/other')
      expect(repository.prune_enabled).to be(true)
      expect(repository.prune_interval).to eq(120)
      expect(repository.prune_older_than_days).to eq(30)
      expect(repository.attrs['org.vpsfree.cz/test:role']).to eq('mirror')
      expect(repository).to have_received(:start_prune)
    end
  end

  it 'disables pruning and stops the prune worker through unset' do
    with_tmpdir do |dir|
      _pool, repository = build_repository(root: dir)
      repository.configure('https://example.invalid/repo')

      allow(repository).to receive(:stop_prune)

      repository.unset(
        prune_enabled: true,
        attrs: []
      )

      expect(repository.prune_enabled).to be(false)
      expect(repository).to have_received(:stop_prune)
    end
  end

  it 'starts pruning only when pruning is enabled' do
    with_tmpdir do |dir|
      _pool, enabled_repository = build_repository(root: File.join(dir, 'enabled'))
      _other_pool, disabled_repository = build_repository(root: File.join(dir, 'disabled'))

      enabled_repository.configure('https://example.invalid/repo')
      disabled_repository.configure('https://example.invalid/repo', prune_enabled: false)

      allow(enabled_repository).to receive(:start_prune)
      allow(disabled_repository).to receive(:start_prune)

      enabled_repository.start
      disabled_repository.start

      expect(enabled_repository).to have_received(:start_prune)
      expect(disabled_repository).not_to have_received(:start_prune)
    end
  end

  it 'delegates stop to stop_prune' do
    with_tmpdir do |dir|
      _pool, repository = build_repository(root: dir)
      allow(repository).to receive(:stop_prune)

      repository.stop

      expect(repository).to have_received(:stop_prune)
    end
  end

  it 'delegates prune_images to OsCtlRepo while holding the cache lock' do
    with_tmpdir do |dir|
      _pool, repository = build_repository(root: dir)
      repository.configure('https://example.invalid/repo')
      locked = false

      osctl_repo = double
      stub_const('OsCtld::OsCtlRepo', Class.new do
        def initialize(*); end
      end)
      allow(OsCtld::OsCtlRepo).to receive(:new).with(repository).and_return(osctl_repo)
      allow(repository).to receive(:with_cache_lock) do |&block|
        locked = true
        block.call
      ensure
        locked = false
      end
      allow(osctl_repo).to receive(:prune_images) do |older_than_days:|
        expect(locked).to be(true)
        expect(older_than_days).to eq(7)
        [true, ['/x.tar']]
      end

      expect(repository.prune_images(older_than_days: 7)).to eq([true, ['/x.tar']])
    end
  end

  it 'exports repository state' do
    with_tmpdir do |dir|
      _pool, repository = build_repository(root: dir)
      repository.configure(
        'https://example.invalid/repo',
        prune_enabled: false,
        prune_interval: 60,
        prune_older_than_days: 7
      )

      expect(repository.export).to eq(
        pool: 'tank',
        name: 'default',
        url: 'https://example.invalid/repo',
        enabled: true,
        prune_enabled: false,
        prune_interval: 60,
        prune_older_than_days: 7
      )
    end
  end
end
