# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp do
  describe '.upgrade' do
    let(:pool_migrations) do
      instance_double(
        OsUp::PoolMigrations,
        pool: 'tank',
        upgradable?: upgradable,
        uptodate?: uptodate?
      )
    end
    let(:upgradable) { true }
    let(:uptodate?) { false }

    before do
      allow(OsUp::PoolMigrations).to receive(:new).with('tank').and_return(pool_migrations)
    end

    it 'raises PoolIncompatible when the pool is not upgradable' do
      allow(pool_migrations).to receive(:upgradable?).and_return(false)

      expect { described_class.upgrade('tank') }
        .to raise_error(OsUp::PoolIncompatible)
    end

    it 'raises PoolUpToDate when the pool is already current' do
      allow(pool_migrations).to receive(:uptodate?).and_return(true)

      expect { described_class.upgrade('tank') }
        .to raise_error(OsUp::PoolUpToDate)
    end

    it 'delegates to Migrator.upgrade with the selected target and dry-run flag' do
      allow(OsUp::Migrator).to receive(:upgrade)

      described_class.upgrade('tank', to: 20_220_406_162_532, dry_run: true)

      expect(OsUp::Migrator).to have_received(:upgrade).with(
        pool_migrations,
        to: 20_220_406_162_532,
        dry_run: true
      )
    end
  end

  describe '.rollback' do
    it 'delegates to Migrator.rollback with the selected target and dry-run flag' do
      pool_migrations = instance_double(OsUp::PoolMigrations)

      allow(OsUp::PoolMigrations).to receive(:new).with('tank').and_return(pool_migrations)
      allow(OsUp::Migrator).to receive(:rollback)

      described_class.rollback('tank', to: 20_190_408_152_558, dry_run: true)

      expect(OsUp::Migrator).to have_received(:rollback).with(
        pool_migrations,
        to: 20_190_408_152_558,
        dry_run: true
      )
    end
  end

  describe '.init' do
    let(:pool_migrations) do
      instance_double(OsUp::PoolMigrations, pool: 'tank', applied:, set_all_up: true)
    end
    let(:applied) { [] }

    before do
      allow(OsUp::PoolMigrations).to receive(:new).with('tank').and_return(pool_migrations)
    end

    it 'raises PoolInUse when migrations already exist and force is false' do
      allow(pool_migrations).to receive(:applied).and_return([1])

      expect { described_class.init('tank') }
        .to raise_error(OsUp::PoolInUse)
    end

    it 'marks all migrations as applied when initialization is allowed' do
      described_class.init('tank')

      expect(pool_migrations).to have_received(:set_all_up)
    end

    it 'bypasses the in-use guard when force is true' do
      allow(pool_migrations).to receive(:applied).and_return([1])

      described_class.init('tank', force: true)

      expect(pool_migrations).to have_received(:set_all_up)
    end
  end

  describe '.root' do
    it 'resolves to the osup project root' do
      expect(described_class.root).to eq(File.join(REPO_ROOT, 'osup'))
    end
  end

  describe '.migration_dir' do
    it 'resolves to the migration directory inside the osup project' do
      expect(described_class.migration_dir).to eq(File.join(REPO_ROOT, 'osup', 'migrations'))
    end
  end
end
