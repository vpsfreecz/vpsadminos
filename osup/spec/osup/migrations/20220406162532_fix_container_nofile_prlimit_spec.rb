# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe '20220406162532-fix-container-nofile-prlimit migration' do
  let(:rel_prefix) { 'migrations/20220406162532-fix-container-nofile-prlimit' }

  def conf_mount_zfs(conf_dir)
    proc do |cmd, opts, target|
      case [cmd, opts, target]
      when [:get, '-Hp -o value mountpoint', 'tank/osctl/conf']
        command_result("#{conf_dir}\n")
      else
        raise "unexpected zfs call: #{[cmd, opts, target].inspect}"
      end
    end
  end

  it 'normalizes nofile prlimit keys during upgrade' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      conf_ct = File.join(conf_dir, 'ct')
      mkdir_p(conf_ct)

      write_yaml_file(File.join(conf_ct, '100.yml'), {
        'prlimits' => {
          nofile: { 'soft' => 1024, 'hard' => 2048 }
        }
      })
      write_yaml_file(File.join(conf_ct, '101.yml'), {
        'prlimits' => {
          :nofile => { 'soft' => 1024 },
          'nofile' => { 'soft' => 4096 }
        }
      })
      write_yaml_file(File.join(conf_ct, '102.yml'), { 'hostname' => 'no-prlimits' })
      write_yaml_file(File.join(conf_ct, '103.yml'), {
        'prlimits' => {
          'cpu' => { 'soft' => 1 }
        }
      })

      load_migration_script(
        "#{rel_prefix}/up.rb",
        globals: { DATASET: 'tank/osctl' },
        zfs: conf_mount_zfs(conf_dir)
      )

      expect(read_yaml_file(File.join(conf_ct, '100.yml'))).to eq(
        'prlimits' => {
          'nofile' => { 'soft' => 1024, 'hard' => 2048 }
        }
      )
      expect(read_yaml_file(File.join(conf_ct, '101.yml'))).to eq(
        'prlimits' => {
          'nofile' => { 'soft' => 4096 }
        }
      )
      expect(read_yaml_file(File.join(conf_ct, '102.yml'))).to eq('hostname' => 'no-prlimits')
      expect(read_yaml_file(File.join(conf_ct, '103.yml'))).to eq(
        'prlimits' => {
          'cpu' => { 'soft' => 1 }
        }
      )
    end
  end

  it 'keeps rollback as a no-op' do
    expect do
      load_migration_script("#{rel_prefix}/down.rb", globals: {})
    end.not_to raise_error
  end
end
# rubocop:enable RSpec/DescribeClass
