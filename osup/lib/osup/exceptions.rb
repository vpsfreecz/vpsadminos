module OsUp
  class PoolIncompatible < StandardError
    attr_reader :pool, :pool_migrations

    def initialize(pool_migrations)
      @pool = pool_migrations.pool
      @pool_migrations = pool_migrations

      super("#{pool} is in an incompatible state and cannot be upgraded")
    end
  end

  class PoolUpToDate < StandardError
    attr_reader :pool, :pool_migrations

    def initialize(pool_migrations)
      @pool = pool_migrations.pool
      @pool_migrations = pool_migrations

      super("#{pool} is up to date")
    end
  end

  class PoolInUse < StandardError
    attr_reader :pool, :pool_migrations

    def initialize(pool_migrations)
      @pool = pool_migrations.pool
      @pool_migrations = pool_migrations

      super("#{pool} is already initialized")
    end
  end
end
