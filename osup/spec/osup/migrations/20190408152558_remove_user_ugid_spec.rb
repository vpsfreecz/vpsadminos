# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe '20190408152558-remove-user-ugid migration' do
  let(:rel_prefix) { 'migrations/20190408152558-remove-user-ugid' }

  it 'stores the current ugid mapping and removes ugid from user configs during upgrade' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      migration_root = File.join(dir, 'migration')
      migration_dir = File.join(migration_root, '20190408152558')
      mkdir_p(File.join(conf_dir, 'user'))

      write_yaml_file(File.join(conf_dir, 'user', 'alice.yml'), { 'ugid' => 100_001, 'type' => 'dynamic' })
      write_yaml_file(File.join(conf_dir, 'user', 'bob.yml'), { 'ugid' => 100_002, 'type' => 'static' })

      zfs_calls = []
      zfs = proc do |cmd, opts, target|
        case [cmd, opts, target]
        when [:create, '-p', 'tank/osctl/migration']
          mkdir_p(migration_root)
          zfs_calls << [cmd, opts, target]
          command_result
        when [:get, '-Hp -o value mountpoint', 'tank/osctl/migration']
          command_result("#{migration_root}\n")
        when [:get, '-Hp -o value mountpoint', 'tank/osctl/conf']
          command_result("#{conf_dir}\n")
        else
          raise "unexpected zfs call: #{[cmd, opts, target].inspect}"
        end
      end

      load_migration_script(
        "#{rel_prefix}/up.rb",
        globals: { DATASET: 'tank/osctl', MIGRATION_ID: 20_190_408_152_558 },
        zfs:
      )

      expect(zfs_calls).to eq([[:create, '-p', 'tank/osctl/migration']])
      expect(read_yaml_file(File.join(conf_dir, 'user', 'alice.yml'))).to eq('type' => 'dynamic')
      expect(read_yaml_file(File.join(conf_dir, 'user', 'bob.yml'))).to eq('type' => 'static')
      expect(read_yaml_file(File.join(migration_dir, 'user_ugids.yml'))).to eq(
        'alice' => 100_001,
        'bob' => 100_002
      )
    end
  end

  it 'restores ugids, removes type, allocates replacements and cleans up during rollback' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      migration_root = File.join(dir, 'migration')
      migration_dir = File.join(migration_root, '20190408152558')
      mkdir_p(File.join(conf_dir, 'user'))
      mkdir_p(migration_dir)

      write_yaml_file(File.join(migration_dir, 'user_ugids.yml'), {
        'alice' => 100_001,
        'bob' => 65_534,
        'carol' => 100_001
      })
      write_yaml_file(File.join(conf_dir, 'user', 'alice.yml'), { 'type' => 'dynamic' })
      write_yaml_file(File.join(conf_dir, 'user', 'bob.yml'), { 'type' => 'dynamic' })
      write_yaml_file(File.join(conf_dir, 'user', 'carol.yml'), { 'type' => 'dynamic' })

      zfs = proc do |cmd, opts, target|
        case [cmd, opts, target]
        when [:get, '-Hp -o value mountpoint', 'tank/osctl/migration']
          command_result("#{migration_root}\n")
        when [:get, '-Hp -o value mountpoint', 'tank/osctl/conf']
          command_result("#{conf_dir}\n")
        else
          raise "unexpected zfs call: #{[cmd, opts, target].inspect}"
        end
      end
      syscmd = proc do |cmd, *_args|
        raise "unexpected syscmd call: #{cmd.inspect}" unless cmd == 'getent passwd'

        command_result("root:x:0:0::/root:/bin/sh\nsystem:x:100100:100100::/:\n")
      end

      load_migration_script(
        "#{rel_prefix}/down.rb",
        globals: { DATASET: 'tank/osctl', MIGRATION_ID: 20_190_408_152_558 },
        zfs:,
        syscmd:
      )

      expect(read_yaml_file(File.join(conf_dir, 'user', 'alice.yml'))).to eq('ugid' => 100_001)
      expect(read_yaml_file(File.join(conf_dir, 'user', 'bob.yml'))).to eq('ugid' => 100_002)
      expect(read_yaml_file(File.join(conf_dir, 'user', 'carol.yml'))).to eq('ugid' => 100_003)
      expect(File.exist?(File.join(migration_dir, 'user_ugids.yml'))).to be(false)
      expect(Dir.exist?(migration_dir)).to be(false)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
