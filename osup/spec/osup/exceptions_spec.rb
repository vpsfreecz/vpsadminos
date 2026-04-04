# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp::PoolIncompatible do
  describe described_class do
    it 'keeps the pool context and exposes a stable message' do
      pool_migrations = instance_double(OsUp::PoolMigrations, pool: 'tank')
      error = described_class.new(pool_migrations)

      expect(error.pool).to eq('tank')
      expect(error.pool_migrations).to equal(pool_migrations)
      expect(error.message).to eq('tank is in an incompatible state and cannot be upgraded')
    end
  end

  describe OsUp::PoolUpToDate do
    it 'keeps the pool context and exposes a stable message' do
      pool_migrations = instance_double(OsUp::PoolMigrations, pool: 'tank')
      error = described_class.new(pool_migrations)

      expect(error.pool).to eq('tank')
      expect(error.pool_migrations).to equal(pool_migrations)
      expect(error.message).to eq('tank is up to date')
    end
  end

  describe OsUp::PoolInUse do
    it 'keeps the pool context and exposes a stable message' do
      pool_migrations = instance_double(OsUp::PoolMigrations, pool: 'tank')
      error = described_class.new(pool_migrations)

      expect(error.pool).to eq('tank')
      expect(error.pool_migrations).to equal(pool_migrations)
      expect(error.message).to eq('tank is already initialized')
    end
  end
end
