# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass

require 'osctld/exceptions'
require 'osctld/command'

module OsCtld
  module Commands
    module Repository; end
  end
end

require 'osctld/commands/repository/add'
require 'osctld/commands/repository/assets'
require 'osctld/commands/repository/delete'
require 'osctld/commands/repository/disable'
require 'osctld/commands/repository/enable'
require 'osctld/commands/repository/image_list'
require 'osctld/commands/repository/image_prune'
require 'osctld/commands/repository/list'
require 'osctld/commands/repository/show'
require 'osctld/commands/repository/set'
require 'osctld/commands/repository/unset'

RSpec.describe 'repository commands' do
  def build_repo
    pool = Struct.new(:name).new('tank')
    attrs = Struct.new(:export).new({ priority: 10 })
    Struct.new(:pool, :name, :url, :attrs, keyword_init: true) do
      attr_accessor :changes, :unset_changes, :enabled_state, :started, :stopped

      def inclusively
        yield
      end

      def enabled?
        enabled_state.nil? ? true : enabled_state
      end

      def export
        { name:, pool: pool.name, url: }
      end

      def assets
        [{ path: "/repo/#{name}" }]
      end

      def cache_path
        "/cache/#{name}"
      end

      def ident
        "#{pool.name}:#{name}"
      end

      def set(changes)
        self.changes = changes
      end

      def unset(changes)
        self.unset_changes = changes
      end

      def enable
        self.enabled_state = true
      end

      def disable
        self.enabled_state = false
      end

      def start
        self.started = true
      end

      def stop
        self.stopped = true
      end

      def prune_images(older_than_days:)
        [true, ["/cache/#{name}/old-image.tar"]]
      end

      def manipulate(_holder, block:, &)
        yield
      end
    end.new(pool:, name: 'default', url: 'https://repo.example', attrs:).tap do |repo|
      repo.changes = nil
      repo.unset_changes = nil
      repo.enabled_state = true
      repo.started = false
      repo.stopped = false
    end
  end

  before do
    history = stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
    allow(history).to receive(:log)
  end

  it 'lists and shows exported repositories merged with attrs' do
    repo = build_repo
    db = stub_const('OsCtld::DB::Repositories', Class.new do
      def self.each_by_ids(_names, _pool); end

      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:each_by_ids).with(['default'], 'tank').and_yield(repo)
    allow(db).to receive(:find).with('default', 'tank').and_return(repo)

    expect(OsCtld::Commands::Repository::List.run(names: ['default'], pool: 'tank')).to eq(
      status: true,
      output: [{ name: 'default', pool: 'tank', url: 'https://repo.example', priority: 10 }]
    )
    expect(OsCtld::Commands::Repository::Show.run(name: 'default', pool: 'tank')).to eq(
      status: true,
      output: {
        pool: 'tank',
        name: 'default',
        url: 'https://repo.example',
        enabled: true,
        priority: 10
      }
    )
  end

  it 'creates repositories in the resolved pool and starts them' do
    pool_class = stub_const('OsCtld::Pool', Class.new do
      attr_reader :name

      def initialize(name)
        @name = name
      end
    end)
    repo_class = stub_const('OsCtld::Repository', Class.new do
      attr_reader :pool, :name, :url, :prune_enabled

      def initialize(pool, name, load: false)
        @pool = pool
        @name = name
      end

      def configure(url, prune_enabled:)
        @url = url
        @prune_enabled = prune_enabled
      end

      def cache_path
        "/cache/#{name}"
      end

      def start; end
    end)
    repo_class.const_set(:UID, 1234)
    pool = pool_class.new('tank')
    pools = stub_const('OsCtld::DB::Pools', Class.new do
      def self.find(_name); end

      def self.get_or_default(_name); end
    end)
    repos = stub_const('OsCtld::DB::Repositories', Class.new do
      def self.sync
        yield
      end

      def self.find(_name, _pool); end

      def self.add(_repo); end
    end)
    allow(pools).to receive(:find).with('tank').and_return(pool)
    allow(repos).to receive(:find).with('extra', pool).and_return(nil)
    allow(repos).to receive(:add).with(instance_of(repo_class))
    allow(Dir).to receive(:mkdir)
    allow(File).to receive(:chown)

    expect(
      OsCtld::Commands::Repository::Add.run(
        name: 'extra',
        pool: 'tank',
        url: 'https://repo2.example',
        prune_enabled: false
      )
    ).to eq(status: true, output: nil)
    expect(Dir).to have_received(:mkdir).with('/cache/extra', 0o700)
    expect(File).to have_received(:chown).with(1234, 0, '/cache/extra')
  end

  it 'exports repository assets through the asset validator' do
    repo = build_repo
    db = stub_const('OsCtld::DB::Repositories', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('default', 'tank').and_return(repo)
    command = OsCtld::Commands::Repository::Assets.new({ name: 'default', pool: 'tank' }, {})
    allow(command).to receive(:list_and_validate_assets).with(repo).and_return([{ path: '/repo/default' }])

    expect(command.execute).to eq(status: true, output: [{ path: '/repo/default' }])
  end

  it 'filters repository set changes to supported keys' do
    repo = build_repo
    db = stub_const('OsCtld::DB::Repositories', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('default', 'tank').and_return(repo)

    ret = OsCtld::Commands::Repository::Set.run(
      name: 'default',
      pool: 'tank',
      url: 'https://repo2.example',
      prune_enabled: true,
      ignored: 'value'
    )

    expect(ret).to eq(status: true, output: nil)
    expect(repo.changes).to eq(url: 'https://repo2.example', prune_enabled: true)
  end

  it 'enables, disables, and unsets repository attributes through manipulate' do
    repo = build_repo
    db = stub_const('OsCtld::DB::Repositories', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('default', 'tank').and_return(repo)

    expect(OsCtld::Commands::Repository::Disable.run(name: 'default', pool: 'tank')).to eq(status: true, output: nil)
    expect(repo.enabled?).to be(false)
    expect(OsCtld::Commands::Repository::Enable.run(name: 'default', pool: 'tank')).to eq(status: true, output: nil)
    expect(repo.enabled?).to be(true)
    expect(
      OsCtld::Commands::Repository::Unset.run(
        name: 'default',
        pool: 'tank',
        prune_enabled: true,
        attrs: %w[priority]
      )
    ).to eq(status: true, output: nil)
    expect(repo.unset_changes).to eq(prune_enabled: true, attrs: %w[priority])
  end

  it 'prevents deleting the default repository and removes non-default repositories' do
    default_repo = build_repo
    extra_repo = build_repo.tap do |repo|
      repo.name = 'extra'
    end
    db = stub_const('OsCtld::DB::Repositories', Class.new do
      def self.find(_name, _pool); end

      def self.remove(_repo); end
    end)
    allow(db).to receive(:find).with('default', 'tank').and_return(default_repo)
    allow(db).to receive(:find).with('extra', 'tank').and_return(extra_repo)
    allow(db).to receive(:remove).with(extra_repo)

    expect do
      OsCtld::Commands::Repository::Delete.run(name: 'default', pool: 'tank')
    end.to raise_error(OsCtld::CommandFailed, 'the default repository cannot be deleted, only disabled')

    command = OsCtld::Commands::Repository::Delete.new({ name: 'extra', pool: 'tank' }, {})
    allow(command).to receive(:syscmd)

    expect(command.base_execute).to eq(status: true, output: nil)
    expect(command).to have_received(:syscmd).with('rm -rf /cache/extra')
    expect(db).to have_received(:remove).with(extra_repo)
  end

  it 'filters repository images and reports pruned files' do
    image1 = Struct.new(:vendor, :variant, :arch, :distribution, :version, :tags, :cached?, :dump).new(
      'vendor', 'default', 'x86_64', 'alpine', '3.19', %w[stable], true, { id: 'cached' }
    )
    image2 = Struct.new(:vendor, :variant, :arch, :distribution, :version, :tags, :cached?, :dump).new(
      'vendor', 'edge', 'x86_64', 'alpine', '3.20', %w[beta], false, { id: 'uncached' }
    )
    repo = build_repo
    db = stub_const('OsCtld::DB::Repositories', Class.new do
      def self.find(_name, _pool); end

      def self.get; end
    end)
    osctl_repo = stub_const('OsCtld::OsCtlRepo', Class.new do
      class << self
        attr_accessor :images
      end

      def initialize(_repo); end

      def list_images
        self.class.images
      end
    end)
    allow(db).to receive(:find).with('default', 'tank').and_return(repo)
    osctl_repo.images = [image1, image2]

    expect(
      OsCtld::Commands::Repository::ImageList.run(
        name: 'default',
        pool: 'tank',
        distribution: 'alpine',
        tag: 'stable',
        cached: true
      )
    ).to eq(status: true, output: [{ id: 'cached' }])

    prune = OsCtld::Commands::Repository::ImagePrune.new(
      { repositories: ['default'], pool: 'tank', older_than_days: 30 },
      {}
    )
    allow(db).to receive(:find).with('default', 'tank').and_return(repo)
    allow(prune).to receive(:progress)

    expect(prune.execute).to eq(status: true, output: nil)
    expect(prune).to have_received(:progress).with('Deleted /cache/default/old-image.tar')
  end
end

# rubocop:enable RSpec/DescribeClass
