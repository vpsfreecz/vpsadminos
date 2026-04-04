# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe '20190408134218-remove-user-datasets migration' do
  let(:rel_prefix) { 'migrations/20190408134218-remove-user-datasets' }

  it 'destroys the user dataset during upgrade' do
    calls = []
    zfs = proc do |cmd, opts, target|
      calls << [cmd, opts, target]
      command_result
    end

    load_migration_script(
      "#{rel_prefix}/up.rb",
      globals: { DATASET: 'tank/osctl' },
      zfs:
    )

    expect(calls).to eq([[:destroy, '-r', 'tank/osctl/user']])
  end

  it 'recreates the user dataset tree and shell helpers during rollback' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      users_dir = File.join(dir, 'user')
      mkdir_p(File.join(conf_dir, 'user'))
      mkdir_p(File.join(conf_dir, 'group', 'default', 'sub'))
      mkdir_p(File.join(conf_dir, 'ct'))

      write_yaml_file(File.join(conf_dir, 'user', 'alice.yml'), { 'ugid' => 100_001 })
      write_yaml_file(File.join(conf_dir, 'user', 'bob.yml'), { 'ugid' => 100_002 })
      write_yaml_file(File.join(conf_dir, 'group', 'default', 'config.yml'), {})
      write_yaml_file(File.join(conf_dir, 'group', 'default', 'sub', 'config.yml'), {})
      write_yaml_file(File.join(conf_dir, 'ct', '100.yml'), { 'user' => 'alice', 'group' => '/default' })
      write_yaml_file(File.join(conf_dir, 'ct', '101.yml'), { 'user' => 'alice', 'group' => '/default/sub' })

      zfs_calls = []
      zfs = proc do |cmd, opts, target|
        case [cmd, opts, target]
        when [:get, '-Hp -o value mountpoint', 'tank/osctl/conf']
          command_result("#{conf_dir}\n")
        when [:create, nil, 'tank/osctl/user']
          mkdir_p(users_dir)
          zfs_calls << [cmd, opts, target]
          command_result
        when [:get, '-Hp -o value mountpoint', 'tank/osctl/user']
          command_result("#{users_dir}\n")
        else
          raise "unexpected zfs call: #{[cmd, opts, target].inspect}" unless cmd == :create && opts.nil? && target.start_with?('tank/osctl/user/')

          mkdir_p(File.join(users_dir, File.basename(target)))
          zfs_calls << [cmd, opts, target]
          command_result

        end
      end

      allow(File).to receive(:chown)

      load_migration_script(
        "#{rel_prefix}/down.rb",
        globals: { DATASET: 'tank/osctl' },
        zfs:
      )

      top_level_ct_dir = File.join(users_dir, 'alice', 'group.default', 'cts', '100')
      nested_ct_dir = File.join(users_dir, 'alice', 'group.default', 'group.sub', 'cts', '101')
      bashrc = File.read(File.join(top_level_ct_dir, '.bashrc'))

      expect(zfs_calls).to include(
        [:create, nil, 'tank/osctl/user'],
        [:create, nil, 'tank/osctl/user/alice'],
        [:create, nil, 'tank/osctl/user/bob']
      )
      expect(Dir.exist?(top_level_ct_dir)).to be(true)
      expect(Dir.exist?(nested_ct_dir)).to be(true)
      expect(Dir.exist?(File.join(users_dir, 'bob'))).to be(true)
      expect(Dir.exist?(File.join(users_dir, 'bob', 'group.default', 'cts'))).to be(false)
      expect(bashrc).to include("alias lxc-attach='lxc-attach -P #{File.dirname(top_level_ct_dir)} -n 100'")
      expect(bashrc).to include('echo "  User:  alice"')
      expect(bashrc).to include('echo "  Group: /default"')
      expect(bashrc).to include('Do not use this shell to manipulate any other container than 100.')
      expect(File).to have_received(:chown).with(0, 100_001, File.dirname(top_level_ct_dir))
      expect(File).to have_received(:chown).with(0, 100_001, top_level_ct_dir)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
