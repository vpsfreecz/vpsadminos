# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp::PoolMigrations do
  def build_migration(id)
    instance_double(OsUp::Migration, id:, name: "Migration #{id}")
  end

  def stub_migration_list(migrations)
    by_id = migrations.to_h { |migration| [migration.id, migration] }
    allow(OsUp::MigrationList).to receive(:get).and_return(migrations)
    allow(OsUp::MigrationList).to receive(:[]) { |id| by_id[id] }
  end

  def pool_migrations_class(pool:, pool_mountpoint:, active:, dataset:, dataset_mountpoint:)
    build_result = lambda do |output|
      CommandResultHelpers::FakeCommandResult.new(output:, exitstatus: 0)
    end

    Class.new(described_class) do
      define_method(:zfs) do |cmd, opts, target|
        case [cmd, opts, target]
        when [
          :get,
          '-Hp -ovalue mountpoint,org.vpsadminos.osctl:active,org.vpsadminos.osctl:dataset',
          pool
        ]
          build_result.call("#{pool_mountpoint}\n#{active}\n#{dataset}\n")
        when [:get, '-Hp -ovalue mountpoint', dataset]
          build_result.call("#{dataset_mountpoint}\n")
        else
          raise "unexpected zfs call: #{[cmd, opts, target].inspect}"
        end
      end
    end
  end

  def build_pool_migrations(
    pool: 'tank',
    known_migrations: [],
    version_contents: nil,
    active: 'yes',
    dataset: 'tank/osctl'
  )
    with_tmpdir do |dir|
      pool_mountpoint = File.join(dir, 'pool')
      dataset_mountpoint = dataset == '-' ? pool_mountpoint : File.join(dir, 'dataset')
      Dir.mkdir(pool_mountpoint)
      Dir.mkdir(dataset_mountpoint) unless dataset == '-'

      version_file = File.join(dataset_mountpoint, described_class::FILE)
      File.write(version_file, version_contents) unless version_contents.nil?

      stub_migration_list(known_migrations)
      klass = pool_migrations_class(
        pool:,
        pool_mountpoint:,
        active:,
        dataset:,
        dataset_mountpoint:
      )

      yield klass.new(pool), version_file, pool_mountpoint, dataset_mountpoint
    end
  end

  it 'loads an active pool with an explicit osctl dataset' do
    build_pool_migrations do |pool_migrations, _version_file, _pool_mountpoint, dataset_mountpoint|
      expect(pool_migrations.pool).to eq('tank')
      expect(pool_migrations.dataset).to eq('tank/osctl')
      expect(pool_migrations.mountpoint).to eq(dataset_mountpoint)
      expect(pool_migrations.version_file).to eq(File.join(dataset_mountpoint, '.migrations'))
    end
  end

  it 'loads an active pool that uses the pool itself as the dataset' do
    build_pool_migrations(dataset: '-') do |pool_migrations, _version_file, pool_mountpoint|
      expect(pool_migrations.dataset).to eq('tank')
      expect(pool_migrations.mountpoint).to eq(pool_mountpoint)
    end
  end

  it 'raises when the pool is inactive' do
    expect do
      build_pool_migrations(active: 'no') { |_pool_migrations, *_args| nil }
    end.to raise_error('pool tank is not used by osctld')
  end

  it 'treats a missing version file as no applied migrations' do
    build_pool_migrations do |pool_migrations, _version_file, *_args|
      expect(pool_migrations.applied).to eq([])
    end
  end

  it 'ignores invalid ids with a warning and de-duplicates applied ids' do
    m2 = build_migration(2)
    m3 = build_migration(3)

    with_tmpdir do |dir|
      pool_mountpoint = File.join(dir, 'pool')
      dataset_mountpoint = File.join(dir, 'dataset')
      version_file = File.join(dataset_mountpoint, described_class::FILE)
      Dir.mkdir(pool_mountpoint)
      Dir.mkdir(dataset_mountpoint)
      File.write(version_file, "0\n-1\ngarbage\n2\n2\n3\n")

      stub_migration_list([m2, m3])
      klass = pool_migrations_class(
        pool: 'tank',
        pool_mountpoint:,
        active: 'yes',
        dataset: 'tank/osctl',
        dataset_mountpoint:
      )

      pool_migrations = nil
      err = capture_stderr do
        pool_migrations = klass.new('tank')
      end

      expect(pool_migrations.applied).to eq([2, 3])
      expect(err.scan("invalid migration id '").count).to eq(3)
    end
  end

  it 'combines known and unknown applied migrations into a sorted unique list' do
    m1 = build_migration(1)
    m3 = build_migration(3)

    build_pool_migrations(
      known_migrations: [m1, m3],
      version_contents: "9\n3\n"
    ) do |pool_migrations, _version_file, *_args|
      expect(pool_migrations.all).to eq([
                                          [1, m1],
                                          [3, m3],
                                          [9, nil]
                                        ])
    end
  end

  it 'reports applied migrations and status helpers' do
    m1 = build_migration(1)
    m2 = build_migration(2)

    build_pool_migrations(
      known_migrations: [m1, m2],
      version_contents: "1\n"
    ) do |pool_migrations, _version_file, *_args|
      yielded = []
      # rubocop:disable Style/MapIntoArray
      pool_migrations.each { |migration| yielded << migration }
      # rubocop:enable Style/MapIntoArray

      expect(pool_migrations.applied?(m1)).to be(true)
      expect(pool_migrations.applied?(m2)).to be(false)
      expect(pool_migrations.uptodate?).to be(false)
      expect(pool_migrations.upgradable?).to be(true)
      expect(yielded).to eq([m1])
    end
  end

  it 'marks a migration up, saves it and rebuilds the list' do
    m1 = build_migration(1)
    m2 = build_migration(2)

    build_pool_migrations(
      known_migrations: [m1, m2],
      version_contents: "1\n"
    ) do |pool_migrations, version_file, *_args|
      pool_migrations.set_up(m2)

      expect(pool_migrations.applied).to eq([1, 2])
      expect(File.read(version_file)).to eq("1\n2\n")
      expect(pool_migrations.all).to eq([[1, m1], [2, m2]])
    end
  end

  it 'marks a migration down, saves it and rebuilds the list' do
    m1 = build_migration(1)
    m2 = build_migration(2)

    build_pool_migrations(
      known_migrations: [m1, m2],
      version_contents: "1\n2\n"
    ) do |pool_migrations, version_file, *_args|
      pool_migrations.set_down(m2)

      expect(pool_migrations.applied).to eq([1])
      expect(File.read(version_file)).to eq("1\n")
      expect(pool_migrations.all).to eq([[1, m1], [2, m2]])
    end
  end

  it 'marks all known migrations as applied' do
    m1 = build_migration(1)
    m2 = build_migration(2)

    build_pool_migrations(
      known_migrations: [m1, m2]
    ) do |pool_migrations, version_file, *_args|
      pool_migrations.set_all_up

      expect(pool_migrations.applied).to eq([1, 2])
      expect(File.read(version_file)).to eq("1\n2\n")
      expect(pool_migrations.uptodate?).to be(true)
    end
  end

  it 'writes the current applied ids when saving' do
    m1 = build_migration(1)
    m2 = build_migration(2)

    build_pool_migrations(
      known_migrations: [m1, m2]
    ) do |pool_migrations, version_file, *_args|
      pool_migrations.instance_variable_set(:@applied, [2, 5])

      pool_migrations.send(:save)

      expect(File.read(version_file)).to eq("2\n5\n")
    end
  end
end
