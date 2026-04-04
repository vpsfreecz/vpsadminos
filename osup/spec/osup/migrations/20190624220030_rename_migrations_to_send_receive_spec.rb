# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe '20190624220030-rename-migrations-to-send-receive migration' do
  let(:rel_prefix) { 'migrations/20190624220030-rename-migrations-to-send-receive' }
  let(:common_path) { File.join(REPO_ROOT, 'osup', rel_prefix, 'common.rb') }

  # Specs run unprivileged, so temporarily reopen the destination directory
  # after creation while still asserting the asset mode configured by osctld.
  def allow_unprivileged_move_to(path)
    allow(FileUtils).to receive(:mkdir_p).and_wrap_original do |orig, *args, **kwargs|
      ret = orig.call(*args, **kwargs)
      File.chmod(0o700, path) if args[0] == path
      ret
    end
  end

  def with_common_loaded(conf_dir)
    zfs = proc do |cmd, opts, target|
      case [cmd, opts, target]
      when [:get, '-Hp -o value mountpoint', 'tank/osctl/conf']
        command_result("#{conf_dir}\n")
      else
        raise "unexpected zfs call: #{[cmd, opts, target].inspect}"
      end
    end

    with_global_vars(DATASET: 'tank/osctl') do
      with_stubbed_system(zfs:) do
        load common_path
        yield RenameMigration.new
      end
    end
  ensure
    # rubocop:disable RSpec/RemoveConst
    Object.send(:remove_const, :RenameMigration) if Object.const_defined?(:RenameMigration)
    # rubocop:enable RSpec/RemoveConst
  end

  it 'renames the pool config directory and removes the old directory when empty' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      old_dir = File.join(conf_dir, 'migration')
      new_dir = File.join(conf_dir, 'send-receive')
      mkdir_p(old_dir)
      File.write(File.join(old_dir, 'state.yml'), "value\n")
      allow_unprivileged_move_to(new_dir)

      with_common_loaded(conf_dir) do |migration|
        migration.rename_pool_config('migration', 'send-receive')
      end

      expect(FileUtils).to have_received(:mkdir_p).with(new_dir, mode: 0o500)
      expect(File.read(File.join(new_dir, 'state.yml'))).to eq("value\n")
      expect(Dir.exist?(old_dir)).to be(false)
    end
  end

  it 'leaves the old directory in place when it is still non-empty' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      old_dir = File.join(conf_dir, 'migration')
      new_dir = File.join(conf_dir, 'send-receive')
      mkdir_p(old_dir)
      File.write(File.join(old_dir, 'state.yml'), "value\n")
      allow_unprivileged_move_to(new_dir)

      allow(Dir).to receive(:empty?).and_call_original
      allow(Dir).to receive(:empty?).with(old_dir).and_return(false)

      with_common_loaded(conf_dir) do |migration|
        migration.rename_pool_config('migration', 'send-receive')
      end

      expect(Dir.exist?(old_dir)).to be(true)
      expect(File.exist?(File.join(conf_dir, 'send-receive', 'state.yml'))).to be(true)
    end
  end

  it 'renames selected container config keys and leaves other configs untouched' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      conf_ct = File.join(conf_dir, 'ct')
      mkdir_p(conf_ct)

      write_yaml_file(File.join(conf_ct, '100.yml'), { 'migration_log' => '/old.log', 'hostname' => 'ct100' })
      write_yaml_file(File.join(conf_ct, '101.yml'), { 'hostname' => 'ct101' })

      with_common_loaded(conf_dir) do |migration|
        migration.rename_ct_configs('migration_log', 'send_log')
      end

      expect(read_yaml_file(File.join(conf_ct, '100.yml'))).to eq(
        'send_log' => '/old.log',
        'hostname' => 'ct100'
      )
      expect(read_yaml_file(File.join(conf_ct, '101.yml'))).to eq('hostname' => 'ct101')
    end
  end

  it 'runs the up wrapper against the real helper' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      conf_ct = File.join(conf_dir, 'ct')
      old_dir = File.join(conf_dir, 'migration')
      mkdir_p(conf_ct)
      mkdir_p(old_dir)
      File.write(File.join(old_dir, 'state.yml'), "value\n")
      write_yaml_file(File.join(conf_ct, '100.yml'), { 'migration_log' => '/old.log' })
      allow_unprivileged_move_to(File.join(conf_dir, 'send-receive'))

      load_migration_script(
        "#{rel_prefix}/up.rb",
        globals: { DATASET: 'tank/osctl' },
        zfs: proc do |cmd, opts, target|
          case [cmd, opts, target]
          when [:get, '-Hp -o value mountpoint', 'tank/osctl/conf']
            command_result("#{conf_dir}\n")
          else
            raise "unexpected zfs call: #{[cmd, opts, target].inspect}"
          end
        end
      )

      expect(Dir.exist?(old_dir)).to be(false)
      expect(File.exist?(File.join(conf_dir, 'send-receive', 'state.yml'))).to be(true)
      expect(read_yaml_file(File.join(conf_ct, '100.yml'))).to eq('send_log' => '/old.log')
    end
  end

  it 'runs the down wrapper against the real helper' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      conf_ct = File.join(conf_dir, 'ct')
      old_dir = File.join(conf_dir, 'send-receive')
      mkdir_p(conf_ct)
      mkdir_p(old_dir)
      File.write(File.join(old_dir, 'state.yml'), "value\n")
      write_yaml_file(File.join(conf_ct, '100.yml'), { 'send_log' => '/old.log' })
      allow_unprivileged_move_to(File.join(conf_dir, 'migration'))

      load_migration_script(
        "#{rel_prefix}/down.rb",
        globals: { DATASET: 'tank/osctl' },
        zfs: proc do |cmd, opts, target|
          case [cmd, opts, target]
          when [:get, '-Hp -o value mountpoint', 'tank/osctl/conf']
            command_result("#{conf_dir}\n")
          else
            raise "unexpected zfs call: #{[cmd, opts, target].inspect}"
          end
        end
      )

      expect(Dir.exist?(old_dir)).to be(false)
      expect(File.exist?(File.join(conf_dir, 'migration', 'state.yml'))).to be(true)
      expect(read_yaml_file(File.join(conf_ct, '100.yml'))).to eq('migration_log' => '/old.log')
    end
  end
end
# rubocop:enable RSpec/DescribeClass
