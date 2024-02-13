require 'require_all'

module OsUp
  # Upgrade pool
  # @param pool [String]
  # @param opts [Hash]
  # @option opts [Integer] :to version to upgrade to
  # @option opts [Boolean] :dry_run
  def self.upgrade(pool, **opts)
    pool_migrations = PoolMigrations.new(pool)

    if !pool_migrations.upgradable?
      raise PoolIncompatible, pool_migrations

    elsif pool_migrations.uptodate?
      raise PoolUpToDate, pool_migrations
    end

    Migrator.upgrade(
      pool_migrations,
      to: opts[:to],
      dry_run: opts[:dry_run]
    )
  end

  # Rollback pool
  # @param pool [String]
  # @param opts [Hash]
  # @option opts [Integer] :to version to rollback to
  # @option opts [Boolean] :dry_run
  def self.rollback(pool, **opts)
    pool_migrations = PoolMigrations.new(pool)

    Migrator.rollback(
      pool_migrations,
      to: opts[:to],
      dry_run: opts[:dry_run]
    )
  end

  # Initialize pool
  # @param pool [String]
  # @param force [Boolean] overwrite existing version file
  def self.init(pool, force: false)
    pool_migrations = PoolMigrations.new(pool)

    if pool_migrations.applied.any? && !force
      raise PoolInUse, pool_migrations
    end

    pool_migrations.set_all_up
  end

  def self.root
    File.join(__dir__, '..')
  end

  def self.migration_dir
    File.join(root, 'migrations')
  end
end

require_rel 'osup/*.rb'
