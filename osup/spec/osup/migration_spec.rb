# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp::Migration do
  def write_migration(dir, dirname, spec: nil)
    path = File.join(dir, dirname)
    Dir.mkdir(path)
    File.write(File.join(path, 'spec.yml'), YAML.dump(spec)) unless spec.nil?
    path
  end

  describe '.load' do
    it 'loads valid migration directories' do
      with_tmpdir do |dir|
        write_migration(dir, '20180711154030-add-netif-routes')

        migration = described_class.load(dir, '20180711154030-add-netif-routes')

        expect(migration.id).to eq(20_180_711_154_030)
        expect(migration.dirname).to eq('20180711154030-add-netif-routes')
      end
    end

    it 'rejects invalid directory names' do
      expect do
        described_class.load('/tmp', 'invalid')
      end.to raise_error("'invalid' is not a valid migration")
    end
  end

  it 'derives the default name from the directory name' do
    with_tmpdir do |dir|
      write_migration(dir, '20180711154030-add-netif-routes')

      migration = described_class.load(dir, '20180711154030-add-netif-routes')

      expect(migration.name).to eq('Add netif routes')
    end
  end

  it 'uses metadata from spec.yml when present' do
    with_tmpdir do |dir|
      write_migration(
        dir,
        '20180711154030-add-netif-routes',
        spec: {
          'name' => 'Custom name',
          'description' => 'Custom description',
          'snapshot' => %w[conf hook]
        }
      )

      migration = described_class.load(dir, '20180711154030-add-netif-routes')

      expect(migration.name).to eq('Custom name')
      expect(migration.description).to eq('Custom description')
      expect(migration.snapshot).to eq(%i[conf hook])
    end
  end

  it 'defaults missing spec.yml to stable values' do
    with_tmpdir do |dir|
      write_migration(dir, '20180711154030-add-netif-routes')

      migration = described_class.load(dir, '20180711154030-add-netif-routes')

      expect(migration.snapshot).to eq([])
      expect(migration.export_pool).to be(true)
      expect(migration.stop_containers).to be(true)
    end
  end

  it 'defaults missing snapshot to an empty array when spec.yml is partial' do
    with_tmpdir do |dir|
      write_migration(
        dir,
        '20180711154030-add-netif-routes',
        spec: {
          'export_pool' => false
        }
      )

      migration = described_class.load(dir, '20180711154030-add-netif-routes')

      expect(migration.snapshot).to eq([])
      expect(migration.export_pool).to be(false)
      expect(migration.stop_containers).to be(true)
    end
  end

  it 'uses explicit booleans while keeping defaults for omitted values' do
    with_tmpdir do |dir|
      write_migration(
        dir,
        '20180711154030-add-netif-routes',
        spec: {
          'stop_containers' => false
        }
      )

      migration = described_class.load(dir, '20180711154030-add-netif-routes')

      expect(migration.export_pool).to be(true)
      expect(migration.stop_containers).to be(false)
    end
  end

  it 'resolves action scripts inside the migration directory' do
    with_tmpdir do |dir|
      migration_path = write_migration(dir, '20180711154030-add-netif-routes')
      migration = described_class.load(dir, '20180711154030-add-netif-routes')

      expect(migration.action_script('up')).to eq(File.join(migration_path, 'up.rb'))
      expect(migration.action_script('down')).to eq(File.join(migration_path, 'down.rb'))
    end
  end
end
