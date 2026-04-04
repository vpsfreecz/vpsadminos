# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp::Cli::Main do
  def build_main_class(**methods)
    Class.new(described_class) do
      attr_reader :calls

      def initialize(*)
        super
        @calls = []
      end
    end.tap do |klass|
      methods.each do |name, body|
        klass.define_method(name, &body)
      end
    end
  end

  def build_main(klass = described_class, args: [], opts: {}, gopts: {})
    build_command(klass, args:, opts:, gopts:)
  end

  def pool_migration_double(pool)
    instance_double(OsUp::PoolMigrations, pool:)
  end

  def migration(id, export_pool: true, stop_containers: true, name: "Migration #{id}")
    instance_double(
      OsUp::Migration,
      id:,
      export_pool:,
      stop_containers:,
      name:
    )
  end

  describe '#status' do
    it 'delegates to pool_status when a pool is given' do
      klass = build_main_class(
        pool_status: proc do |pool|
          calls << [:pool_status, pool]
        end
      )
      command = build_main(klass, args: ['tank'])

      command.status

      expect(command.calls).to eq([[:pool_status, 'tank']])
    end

    it 'delegates to global_status when no pool is given' do
      klass = build_main_class(
        global_status: proc do
          calls << [:global_status]
        end
      )
      command = build_main(klass)

      command.status

      expect(command.calls).to eq([[:global_status]])
    end

    it 'validates the argument count' do
      command = build_main(args: %w[tank extra])

      expect { command.status }
        .to raise_error(GLI::BadCommandLine, 'unknown argument: extra')
    end
  end

  describe '#check' do
    it 'delegates to pool_check when a pool is given' do
      klass = build_main_class(
        pool_check: proc do |pool|
          calls << [:pool_check, pool]
        end
      )
      command = build_main(klass, args: ['tank'])

      command.check

      expect(command.calls).to eq([[:pool_check, 'tank']])
    end

    it 'delegates to global_check when no pool is given' do
      klass = build_main_class(
        global_check: proc do
          calls << [:global_check]
        end
      )
      command = build_main(klass)

      command.check

      expect(command.calls).to eq([[:global_check]])
    end
  end

  describe '#check_rollback' do
    it 'prints the rollback flags for the selected target' do
      pool_migrations = pool_migration_double('tank')
      klass = build_main_class(
        pool_flags_rollback: proc do |state, version|
          calls << [:pool_flags_rollback, state, version]
          'export'
        end
      )
      command = build_main(klass, args: %w[tank 123])

      allow(OsUp::PoolMigrations).to receive(:new).with('tank').and_return(pool_migrations)

      out = capture_stdout { command.check_rollback }

      expect(out).to eq("export\n")
      expect(command.calls).to eq([[:pool_flags_rollback, pool_migrations, 123]])
    end
  end

  describe '#init' do
    it 'forwards the force flag' do
      command = build_main(args: ['tank'], opts: { force: true })

      allow(OsUp).to receive(:init)

      command.init

      expect(OsUp).to have_received(:init).with('tank', force: true)
    end
  end

  describe '#upgrade' do
    it 'forwards the target version and dry-run flag' do
      command = build_main(args: %w[tank 5], gopts: { 'dry-run' => true })

      allow(OsUp).to receive(:upgrade)

      command.upgrade

      expect(OsUp).to have_received(:upgrade).with('tank', to: 5, dry_run: true)
    end

    it 'prints the up-to-date message instead of raising' do
      command = build_main(args: %w[tank 5])
      pool_migrations = pool_migration_double('tank')

      allow(OsUp).to receive(:upgrade).and_raise(OsUp::PoolUpToDate.new(pool_migrations))

      out = capture_stdout { command.upgrade }

      expect(out).to eq("tank is up to date\n")
    end
  end

  describe '#upgrade_all' do
    it 'forwards to: and dry-run, skips PoolUpToDate and warns on failures' do
      pools = %w[tank1 tank2 tank3]
      pool_migrations = pools.to_h { |pool| [pool, pool_migration_double(pool)] }
      klass = build_main_class(
        active_pools: proc { pools }
      )
      command = build_main(klass, args: ['5'], gopts: { 'dry-run' => true })
      calls = []

      allow(OsUp::PoolMigrations).to receive(:new)
      allow(OsUp).to receive(:upgrade) do |pool, **kwargs|
        calls << [pool, kwargs]

        case pool
        when 'tank1'
          # rubocop:disable Style/RaiseArgs
          raise OsUp::PoolUpToDate.new(pool_migrations.fetch(pool))
          # rubocop:enable Style/RaiseArgs
        when 'tank2'
          raise 'upgrade failed'
        end
      end

      err = capture_stderr do
        expect { command.upgrade_all }.not_to raise_error
      end

      expect(calls).to eq(
        [
          ['tank1', { to: 5, dry_run: true }],
          ['tank2', { to: 5, dry_run: true }],
          ['tank3', { to: 5, dry_run: true }]
        ]
      )
      expect(OsUp::PoolMigrations).not_to have_received(:new)
      expect(err).to include("upgrade failed\n")
    end
  end

  describe '#rollback' do
    it 'forwards the target version and dry-run flag' do
      command = build_main(args: %w[tank 4], gopts: { 'dry-run' => true })

      allow(OsUp).to receive(:rollback)

      command.rollback

      expect(OsUp).to have_received(:rollback).with('tank', to: 4, dry_run: true)
    end
  end

  describe '#rollback_all' do
    it 'warns and continues when one pool fails' do
      klass = build_main_class(
        active_pools: proc { %w[tank1 tank2] }
      )
      command = build_main(klass, args: ['4'], gopts: { 'dry-run' => true })
      calls = []

      allow(OsUp).to receive(:rollback) do |pool, **kwargs|
        calls << [pool, kwargs]
        raise 'rollback failed' if pool == 'tank1'
      end

      err = capture_stderr do
        expect { command.rollback_all }.not_to raise_error
      end

      expect(calls).to eq(
        [
          ['tank1', { to: 4, dry_run: true }],
          ['tank2', { to: 4, dry_run: true }]
        ]
      )
      expect(err).to include("rollback failed\n")
    end
  end

  describe '#gen_bash_completion' do
    it 'prints bash completion output' do
      command = build_main
      app = instance_double(OsUp::Cli::App)
      generator = instance_double(
        OsCtl::Lib::Cli::Completion::Bash,
        generate: 'completion-script'
      )

      allow(OsUp::Cli::App).to receive(:get).and_return(app)
      allow(OsCtl::Lib::Cli::Completion::Bash).to receive(:new).with(app).and_return(generator)

      out = capture_stdout { command.gen_bash_completion }

      expect(out).to eq("completion-script\n")
    end
  end

  describe 'protected helpers' do
    describe '#active_pools' do
      it 'returns only active pools' do
        klass = build_main_class(
          zfs: proc do |cmd, opts, target|
            calls << [:zfs, cmd, opts, target]
            CommandResultHelpers::FakeCommandResult.new(
              output: "tank yes\nother no\nfast yes\n",
              exitstatus: 0
            )
          end
        )
        command = build_main(klass)

        expect(command.send(:active_pools)).to eq(%w[tank fast])
        expect(command.calls).to eq(
          [
            [:zfs, :list, '-r -d0 -H -o name,org.vpsadminos.osctl:active', '']
          ]
        )
      end
    end

    describe '#pool_state' do
      it 'returns incompatible when the pool cannot be upgraded' do
        command = build_main
        pool_migrations = instance_double(OsUp::PoolMigrations, upgradable?: false, uptodate?: false)

        expect(command.send(:pool_state, pool_migrations)).to eq('incompatible')
      end

      it 'returns ok when the pool is up to date' do
        command = build_main
        pool_migrations = instance_double(OsUp::PoolMigrations, upgradable?: true, uptodate?: true)

        expect(command.send(:pool_state, pool_migrations)).to eq('ok')
      end

      it 'returns outdated when there are pending migrations' do
        command = build_main
        pool_migrations = instance_double(OsUp::PoolMigrations, upgradable?: true, uptodate?: false)

        expect(command.send(:pool_state, pool_migrations)).to eq('outdated')
      end
    end

    describe '#pool_flags_upgrade' do
      it 'builds flags from the upgrade sequence' do
        command = build_main
        pool_migrations = pool_migration_double('tank')
        planned = migration(1, export_pool: false, stop_containers: true)

        allow(OsUp::Migrator).to receive(:upgrade_sequence).with(pool_migrations).and_return([planned])

        expect(command.send(:pool_flags_upgrade, pool_migrations)).to eq('stop')
      end
    end

    describe '#pool_flags_rollback' do
      it 'builds flags from the rollback sequence' do
        command = build_main
        pool_migrations = pool_migration_double('tank')
        planned = migration(1, export_pool: true, stop_containers: false)

        allow(OsUp::Migrator).to receive(:rollback_sequence)
          .with(pool_migrations, to: 123)
          .and_return([planned])

        expect(command.send(:pool_flags_rollback, pool_migrations, 123)).to eq('export')
      end
    end

    describe '#pool_flags' do
      it 'returns export,stop when both flags are required' do
        command = build_main

        expect(command.send(:pool_flags, [migration(1)])).to eq('export,stop')
      end

      it 'returns export when only export is required' do
        command = build_main

        expect(command.send(:pool_flags, [migration(1, stop_containers: false)])).to eq('export')
      end

      it 'returns stop when only stop is required' do
        command = build_main

        expect(command.send(:pool_flags, [migration(1, export_pool: false)])).to eq('stop')
      end

      it 'returns - when neither flag is required' do
        command = build_main

        expect(
          command.send(:pool_flags, [migration(1, export_pool: false, stop_containers: false)])
        ).to eq('-')
      end
    end

    describe '#global_status' do
      it 'prints status rows for all active pools' do
        m1 = migration(1)
        m2 = migration(2)
        pool_migrations = instance_double(
          OsUp::PoolMigrations,
          all: [[1, m1], [2, m2], [9, nil]],
          applied?: false
        )
        klass = build_main_class(
          active_pools: proc { ['tank'] },
          pool_state: proc do |state|
            calls << [:pool_state, state]
            'outdated'
          end
        )
        command = build_main(klass)

        allow(OsUp::PoolMigrations).to receive(:new).with('tank').and_return(pool_migrations)
        allow(pool_migrations).to receive(:applied?) { |planned| planned == m1 }

        out = capture_stdout { command.send(:global_status) }

        expect(out).to include('POOL')
        expect(out).to include('tank')
        expect(out).to include('outdated')
        expect(out).to include('3')
        expect(out).to include('2')
        expect(out).to include('1')
        expect(command.calls).to eq([[:pool_state, pool_migrations]])
      end
    end

    describe '#pool_status' do
      it 'prints the status of every known and unknown migration' do
        m1 = migration(1, name: 'First')
        m2 = migration(2, name: 'Second')
        pool_migrations = instance_double(
          OsUp::PoolMigrations,
          all: [[1, m1], [2, m2], [9, nil]]
        )
        command = build_main

        allow(OsUp::PoolMigrations).to receive(:new).with('tank').and_return(pool_migrations)
        allow(pool_migrations).to receive(:applied?) { |planned| planned == m1 }

        out = capture_stdout { command.send(:pool_status, 'tank') }

        expect(out).to include('MIGRATION')
        expect(out).to include('1')
        expect(out).to include('up')
        expect(out).to include('First')
        expect(out).to include('** migration not found **')
      end
    end

    describe '#global_check' do
      it 'checks every active pool' do
        klass = build_main_class(
          active_pools: proc { %w[tank fast] },
          pool_check: proc do |pool|
            calls << [:pool_check, pool]
          end
        )
        command = build_main(klass)

        command.send(:global_check)

        expect(command.calls).to eq(
          [
            [:pool_check, 'tank'],
            [:pool_check, 'fast']
          ]
        )
      end
    end

    describe '#pool_check' do
      it 'prints the required flags for outdated pools' do
        pool_migrations = pool_migration_double('tank')
        latest = instance_double(OsUp::Migration, id: 20_220_406_162_532)
        klass = build_main_class(
          pool_state: proc do |state|
            calls << [:pool_state, state]
            'outdated'
          end,
          pool_flags_upgrade: proc do |state|
            calls << [:pool_flags_upgrade, state]
            'export,stop'
          end
        )
        command = build_main(klass)

        allow(OsUp::PoolMigrations).to receive(:new).with('tank').and_return(pool_migrations)
        allow(OsUp::MigrationList).to receive(:get).and_return([latest])

        out = capture_stdout { command.send(:pool_check, 'tank') }

        expect(out).to include('tank')
        expect(out).to include('outdated')
        expect(out).to include('20220406162532')
        expect(out).to include('export,stop')
        expect(command.calls).to eq(
          [
            [:pool_state, pool_migrations],
            [:pool_flags_upgrade, pool_migrations]
          ]
        )
      end

      it 'prints - for pools that do not need an upgrade' do
        pool_migrations = pool_migration_double('tank')
        latest = instance_double(OsUp::Migration, id: 20_220_406_162_532)
        klass = build_main_class(
          pool_state: proc do |state|
            calls << [:pool_state, state]
            'ok'
          end,
          pool_flags_upgrade: proc do |state|
            calls << [:pool_flags_upgrade, state]
            'export,stop'
          end
        )
        command = build_main(klass)

        allow(OsUp::PoolMigrations).to receive(:new).with('tank').and_return(pool_migrations)
        allow(OsUp::MigrationList).to receive(:get).and_return([latest])

        out = capture_stdout { command.send(:pool_check, 'tank') }

        expect(out).to include('ok')
        expect(out).to include(' -')
        expect(command.calls).to eq([[:pool_state, pool_migrations]])
      end
    end
  end
end
