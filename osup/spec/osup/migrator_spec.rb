# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp::Migrator do
  def build_migration(id, dirname: "#{id}-migration", snapshot: %i[conf], name: "Migration #{id}")
    instance_double(OsUp::Migration, id:, dirname:, snapshot:, name:)
  end

  def build_pool_migrations(all_migrations: [], applied_ids: [])
    instance_double(
      OsUp::PoolMigrations,
      pool: 'tank',
      dataset: 'tank/osctl',
      all: all_migrations
    ).tap do |pool_migrations|
      allow(pool_migrations).to receive(:applied?) do |migration|
        applied_ids.include?(migration.id)
      end
    end
  end

  describe '.upgrade_sequence' do
    it 'returns unapplied migrations in order' do
      first = build_migration(1)
      second = build_migration(2)
      third = build_migration(3)
      pool_migrations = build_pool_migrations(
        all_migrations: [[1, first], [2, second], [3, third]],
        applied_ids: [1]
      )

      expect(described_class.upgrade_sequence(pool_migrations)).to eq([second, third])
    end

    it 'rejects unknown migrations already present in the pool state' do
      first = build_migration(1)
      third = build_migration(3)
      pool_migrations = build_pool_migrations(
        all_migrations: [[1, first], [4, nil], [5, third]],
        applied_ids: [1]
      )

      expect do
        described_class.upgrade_sequence(pool_migrations)
      end.to raise_error('unable to upgrade pool tank: unrecognized migration 4')
    end

    it 'trims the list to the selected reachable target' do
      first = build_migration(1)
      second = build_migration(2)
      third = build_migration(3)
      pool_migrations = build_pool_migrations(
        all_migrations: [[1, first], [2, second], [3, third]],
        applied_ids: [1]
      )

      expect(described_class.upgrade_sequence(pool_migrations, to: 2)).to eq([second])
    end

    it 'raises when the target migration is not reachable' do
      first = build_migration(1)
      second = build_migration(2)
      third = build_migration(3)
      pool_migrations = build_pool_migrations(
        all_migrations: [[1, first], [2, second], [3, third]],
        applied_ids: [1]
      )

      expect do
        described_class.upgrade_sequence(pool_migrations, to: 99)
      end.to raise_error('unable to upgrade pool tank: target migration 99 not found or reachable')
    end
  end

  describe '.rollback_sequence' do
    it 'rolls back the most recent applied migration by default' do
      first = build_migration(1)
      second = build_migration(2)
      third = build_migration(3)
      pool_migrations = build_pool_migrations(
        all_migrations: [[1, first], [2, second], [3, third]],
        applied_ids: [1, 2]
      )

      expect(described_class.rollback_sequence(pool_migrations)).to eq([second])
    end

    it 'returns migrations newer than the selected target' do
      first = build_migration(1)
      second = build_migration(2)
      third = build_migration(3)
      pool_migrations = build_pool_migrations(
        all_migrations: [[1, first], [2, second], [3, third]],
        applied_ids: [1, 2]
      )

      expect(described_class.rollback_sequence(pool_migrations, to: 1)).to eq([second])
    end

    it 'raises when the target migration is not found' do
      first = build_migration(1)
      second = build_migration(2)
      third = build_migration(3)
      pool_migrations = build_pool_migrations(
        all_migrations: [[1, first], [2, second], [3, third]],
        applied_ids: [1, 2]
      )

      expect do
        described_class.rollback_sequence(pool_migrations, to: 99)
      end.to raise_error('unable to rollback pool tank: migration 99 not found or reacheable')
    end

    it 'raises when there are no applied migrations' do
      first = build_migration(1)
      pool_migrations = build_pool_migrations(
        all_migrations: [[1, first]],
        applied_ids: []
      )
      allow(pool_migrations).to receive(:applied?).and_return(false)

      expect do
        described_class.rollback_sequence(pool_migrations)
      end.to raise_error('unable to rollback pool tank: no applied migration found')
    end

    it 'raises the intended error when the target is the latest applied migration' do
      first = build_migration(1)
      second = build_migration(2)
      third = build_migration(3)
      pool_migrations = build_pool_migrations(
        all_migrations: [[1, first], [2, second], [3, third]],
        applied_ids: [1, 2]
      )

      expect do
        described_class.rollback_sequence(pool_migrations, to: 2)
      end.to raise_error(
        'unable to rollback pool tank: would rollback migration 2, but it is set as the target'
      )
    end
  end

  describe '.upgrade' do
    it 'prints a dry-run plan and does not instantiate a migrator' do
      pool_migrations = build_pool_migrations
      planned = [build_migration(1), build_migration(2)]

      allow(described_class).to receive(:upgrade_sequence).and_return(planned)
      allow(described_class).to receive(:new)

      out = capture_stdout do
        described_class.upgrade(pool_migrations, dry_run: true)
      end

      expect(out).to eq("> would up 1\n> would up 2\n")
      expect(described_class).not_to have_received(:new)
    end

    it 'runs the migrator when not in dry-run mode' do
      pool_migrations = build_pool_migrations
      planned = [build_migration(1)]
      migrator = instance_double(described_class, run: true)

      allow(described_class).to receive(:upgrade_sequence).and_return(planned)
      allow(described_class).to receive(:new).with(pool_migrations, planned).and_return(migrator)

      described_class.upgrade(pool_migrations, to: 1)

      expect(migrator).to have_received(:run).with(:up)
    end
  end

  describe '.rollback' do
    it 'prints a dry-run plan and does not instantiate a migrator' do
      pool_migrations = build_pool_migrations
      planned = [build_migration(2)]

      allow(described_class).to receive(:rollback_sequence).and_return(planned)
      allow(described_class).to receive(:new)

      out = capture_stdout do
        described_class.rollback(pool_migrations, dry_run: true)
      end

      expect(out).to eq("> would down 2\n")
      expect(described_class).not_to have_received(:new)
    end

    it 'runs the migrator when not in dry-run mode' do
      pool_migrations = build_pool_migrations
      planned = [build_migration(2)]
      migrator = instance_double(described_class, run: true)

      allow(described_class).to receive(:rollback_sequence).and_return(planned)
      allow(described_class).to receive(:new).with(pool_migrations, planned).and_return(migrator)

      described_class.rollback(pool_migrations, to: 1)

      expect(migrator).to have_received(:run).with(:down)
    end
  end

  describe '#run' do
    it 'prints progress, runs migrations and marks them as up' do
      pool_migrations = build_pool_migrations
      first = build_migration(1)
      second = build_migration(2)
      migrator = described_class.new(pool_migrations, [first, second])

      allow(migrator).to receive(:run_migration).and_return(true)
      allow(pool_migrations).to receive(:set_up)

      out = capture_stdout { migrator.run(:up) }

      expect(out).to eq("> up 1 - Migration 1\n> up 2 - Migration 2\n")
      expect(migrator).to have_received(:run_migration).with(first, :up)
      expect(migrator).to have_received(:run_migration).with(second, :up)
      expect(pool_migrations).to have_received(:set_up).with(first)
      expect(pool_migrations).to have_received(:set_up).with(second)
    end

    it 'raises on the first failed migration and stops processing' do
      pool_migrations = build_pool_migrations
      first = build_migration(1)
      second = build_migration(2)
      migrator = described_class.new(pool_migrations, [first, second])

      allow(migrator).to receive(:run_migration).with(first, :up).and_return(true)
      allow(migrator).to receive(:run_migration).with(second, :up).and_return(false)
      allow(pool_migrations).to receive(:set_up)

      expect { migrator.run(:up) }
        .to raise_error('migration 2 returned non-zero exit status')

      expect(pool_migrations).to have_received(:set_up).with(first)
      expect(pool_migrations).not_to have_received(:set_up).with(second)
    end
  end

  describe '#run_migration' do
    it 'commits the preserved state when the migration succeeds' do
      pool_migrations = build_pool_migrations
      migration = build_migration(
        20_220_406_162_532,
        dirname: '20220406162532-fix',
        snapshot: %i[conf hook]
      )
      migrator = described_class.new(pool_migrations, [migration])
      state = instance_double(OsUp::SystemState, commit: nil, rollback: nil)
      exec_args = []

      allow(OsUp::SystemState).to receive(:create).and_return(state)
      allow(ENV).to receive(:keep_if) do |&block|
        ENV.to_h.keep_if(&block)
      end
      allow(Process).to receive(:exec) do |*args|
        exec_args << args
        throw :exec_called
      end
      allow(Process).to receive(:fork) do |&block|
        catch(:exec_called) { block.call }
        12_345
      end
      allow(Process).to receive(:wait) do |_pid|
        system('true')
        12_345
      end

      expect(migrator.send(:run_migration, migration, :up)).to be(true)
      expect(OsUp::SystemState).to have_received(:create).with(
        'tank/osctl',
        '20220406162532-up',
        snapshot: %i[conf hook]
      )
      expect(exec_args).to eq(
        [
          [
            '/run/current-system/sw/bin/osup',
            'run',
            'tank',
            'tank/osctl',
            '20220406162532-fix',
            'up'
          ]
        ]
      )
      expect(state).to have_received(:commit)
      expect(state).not_to have_received(:rollback)
    end

    it 'rolls the preserved state back when the migration fails' do
      pool_migrations = build_pool_migrations
      migration = build_migration(
        20_220_406_162_532,
        dirname: '20220406162532-fix',
        snapshot: %i[conf hook]
      )
      migrator = described_class.new(pool_migrations, [migration])
      state = instance_double(OsUp::SystemState, commit: nil, rollback: nil)
      exec_args = []

      allow(OsUp::SystemState).to receive(:create).and_return(state)
      allow(ENV).to receive(:keep_if) do |&block|
        ENV.to_h.keep_if(&block)
      end
      allow(Process).to receive(:exec) do |*args|
        exec_args << args
        throw :exec_called
      end
      allow(Process).to receive(:fork) do |&block|
        catch(:exec_called) { block.call }
        12_345
      end
      allow(Process).to receive(:wait) do |_pid|
        system('false')
        12_345
      end

      expect(migrator.send(:run_migration, migration, :down)).to be(false)
      expect(exec_args).to eq(
        [
          [
            '/run/current-system/sw/bin/osup',
            'run',
            'tank',
            'tank/osctl',
            '20220406162532-fix',
            'down'
          ]
        ]
      )
      expect(state).to have_received(:rollback)
      expect(state).not_to have_received(:commit)
    end
  end
end
