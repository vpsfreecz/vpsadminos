# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe '20190814085557-add-dev-kmsg migration' do
  let(:rel_prefix) { 'migrations/20190814085557-add-dev-kmsg' }
  let(:common_path) { File.join(REPO_ROOT, 'osup', rel_prefix, 'common.rb') }

  def with_common_loaded(conf_dir = nil)
    zfs = proc do |cmd, opts, target|
      case [cmd, opts, target]
      when [:get, '-Hp -o value mountpoint', 'tank/osctl/conf']
        command_result("#{conf_dir}\n")
      else
        raise "unexpected zfs call: #{[cmd, opts, target].inspect}"
      end
    end

    with_global_vars(DATASET: 'tank/osctl') do
      with_stubbed_system(zfs: conf_dir ? zfs : nil) do
        load common_path
        yield
      end
    end
  ensure
    # rubocop:disable RSpec/RemoveConst
    %i[Pool GroupConfig DeviceList Device].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
    # rubocop:enable RSpec/RemoveConst
  end

  it 'matches exact and wildcard devices with mode inclusion' do
    with_common_loaded do
      exact = Device.new(
        'type' => 'char',
        'major' => '1',
        'minor' => '11',
        'mode' => 'rwm',
        'name' => '/dev/kmsg',
        'inherit' => true,
        'inherited' => false
      )
      wildcard = Device.new(
        'type' => 'char',
        'major' => '1',
        'minor' => '*',
        'mode' => 'rw',
        'name' => '/dev/any',
        'inherit' => false,
        'inherited' => false
      )
      requested = Device.new(
        'type' => 'char',
        'major' => '1',
        'minor' => '11',
        'mode' => 'r',
        'name' => '/dev/kmsg',
        'inherit' => true,
        'inherited' => false
      )

      expect(exact.include?(requested)).to be(true)
      expect(wildcard.include?(requested)).to be(true)
      expect(wildcard.mode_include?('rw', 'm')).to be(false)
    end
  end

  it 'inserts new devices in sorted order and avoids duplicates' do
    with_common_loaded do
      devices = DeviceList.new([
                                 {
                                   'type' => 'char',
                                   'major' => '2',
                                   'minor' => '0',
                                   'mode' => 'rwm',
                                   'name' => '/dev/two',
                                   'inherit' => true,
                                   'inherited' => false
                                 },
                                 {
                                   'type' => 'char',
                                   'major' => '4',
                                   'minor' => '0',
                                   'mode' => 'rwm',
                                   'name' => '/dev/four',
                                   'inherit' => true,
                                   'inherited' => false
                                 }
                               ])

      devices.ensure(Device.new(
                       'type' => 'char',
                       'major' => '3',
                       'minor' => '0',
                       'mode' => 'rwm',
                       'name' => '/dev/three',
                       'inherit' => true,
                       'inherited' => false
                     ))
      devices.ensure(Device.new(devices.dump[1]))

      expect(devices.dump.map { |device| device['major'] }).to eq(%w[2 3 4])
    end
  end

  it 'upgrades inherit on exact matches and inserts specific devices for wildcard matches when needed' do
    with_common_loaded do
      exact = DeviceList.new([
                               {
                                 'type' => 'char',
                                 'major' => '1',
                                 'minor' => '11',
                                 'mode' => 'rwm',
                                 'name' => '/dev/kmsg',
                                 'inherit' => false,
                                 'inherited' => false
                               }
                             ])
      wildcard = DeviceList.new([
                                  {
                                    'type' => 'char',
                                    'major' => '1',
                                    'minor' => '*',
                                    'mode' => 'rwm',
                                    'name' => '/dev/any',
                                    'inherit' => false,
                                    'inherited' => false
                                  }
                                ])
      requested = Device.new(
        'type' => 'char',
        'major' => '1',
        'minor' => '11',
        'mode' => 'rwm',
        'name' => '/dev/kmsg',
        'inherit' => true,
        'inherited' => false
      )

      exact.ensure(requested)
      wildcard.ensure(requested)

      expect(exact.dump.first['inherit']).to be(true)
      expect(wildcard.dump.map { |device| [device['major'], device['minor']] }).to eq([
                                                                                        ['1', '*'],
                                                                                        ['1', '11']
                                                                                      ])
    end
  end

  it 'loads group configs, updates devices and saves them back' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      group_dir = File.join(conf_dir, 'group')
      mkdir_p(group_dir)
      write_yaml_file(File.join(group_dir, 'config.yml'), { 'devices' => [] })

      with_common_loaded(conf_dir) do
        pool = Pool.new
        group = GroupConfig.new(pool, '/')
        group.ensure_device(Device.new(
                              'type' => 'char',
                              'major' => '1',
                              'minor' => '11',
                              'mode' => 'rwm',
                              'name' => '/dev/kmsg',
                              'inherit' => true,
                              'inherited' => false
                            ))
        group.save
      end

      expect(read_yaml_file(File.join(group_dir, 'config.yml'))['devices']).to eq([
                                                                                    {
                                                                                      'type' => 'char',
                                                                                      'major' => '1',
                                                                                      'minor' => '11',
                                                                                      'mode' => 'rwm',
                                                                                      'name' => '/dev/kmsg',
                                                                                      'inherit' => true,
                                                                                      'inherited' => false
                                                                                    }
                                                                                  ])
    end
  end

  it 'adds /dev/kmsg to the root group in the up wrapper' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      group_dir = File.join(conf_dir, 'group')
      mkdir_p(group_dir)
      write_yaml_file(File.join(group_dir, 'config.yml'), { 'devices' => [] })

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

      expect(read_yaml_file(File.join(group_dir, 'config.yml'))['devices']).to eq([
                                                                                    {
                                                                                      'type' => 'char',
                                                                                      'major' => '1',
                                                                                      'minor' => '11',
                                                                                      'mode' => 'rwm',
                                                                                      'name' => '/dev/kmsg',
                                                                                      'inherit' => true,
                                                                                      'inherited' => false
                                                                                    }
                                                                                  ])
    end
  end

  it 'keeps rollback as a no-op' do
    expect do
      load_migration_script("#{rel_prefix}/down.rb", globals: {})
    end.not_to raise_error
  end
end
# rubocop:enable RSpec/DescribeClass
