# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe '20180711154030-add-netif-routes migration' do
  let(:rel_prefix) { 'migrations/20180711154030-add-netif-routes' }

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

  it 'copies routed interface routes from ip_addresses when upgrading' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      conf_ct = File.join(conf_dir, 'ct')
      mkdir_p(conf_ct)

      write_yaml_file(
        File.join(conf_ct, '100.yml'),
        {
          'net_interfaces' => [
            {
              'name' => 'eth0',
              'type' => 'routed',
              'ip_addresses' => {
                'v4' => ['192.0.2.10/32'],
                'v6' => ['2001:db8::10/128']
              }
            },
            {
              'name' => 'eth1',
              'type' => 'routed',
              'ip_addresses' => {
                'v4' => ['192.0.2.20/32']
              },
              'routes' => {
                'v4' => ['198.51.100.1/32'],
                'v6' => []
              }
            },
            {
              'name' => 'eth2',
              'type' => 'bridge',
              'ip_addresses' => {
                'v4' => ['203.0.113.10/32']
              }
            }
          ]
        }
      )
      write_yaml_file(File.join(conf_ct, '101.yml'), { 'hostname' => 'without-netifs' })

      load_migration_script(
        "#{rel_prefix}/up.rb",
        globals: { DATASET: 'tank/osctl' },
        zfs: conf_mount_zfs(conf_dir)
      )

      upgraded = read_yaml_file(File.join(conf_ct, '100.yml'))

      expect(upgraded['net_interfaces'][0]['routes']).to eq(
        'v4' => ['192.0.2.10/32'],
        'v6' => ['2001:db8::10/128']
      )
      expect(upgraded['net_interfaces'][1]['routes']).to eq(
        'v4' => ['198.51.100.1/32'],
        'v6' => []
      )
      expect(upgraded['net_interfaces'][2]).not_to have_key('routes')
      expect(read_yaml_file(File.join(conf_ct, '101.yml'))).to eq('hostname' => 'without-netifs')
    end
  end

  it 'removes routed interface routes when rolling back' do
    with_tmpdir do |dir|
      conf_dir = File.join(dir, 'conf')
      conf_ct = File.join(conf_dir, 'ct')
      mkdir_p(conf_ct)

      write_yaml_file(
        File.join(conf_ct, '100.yml'),
        {
          'net_interfaces' => [
            {
              'name' => 'eth0',
              'type' => 'routed',
              'routes' => {
                'v4' => ['192.0.2.10/32'],
                'v6' => []
              }
            },
            {
              'name' => 'eth1',
              'type' => 'bridge',
              'routes' => {
                'v4' => ['198.51.100.1/32']
              }
            }
          ]
        }
      )

      load_migration_script(
        "#{rel_prefix}/down.rb",
        globals: { DATASET: 'tank/osctl' },
        zfs: conf_mount_zfs(conf_dir)
      )

      rolled_back = read_yaml_file(File.join(conf_ct, '100.yml'))

      expect(rolled_back['net_interfaces'][0]).not_to have_key('routes')
      expect(rolled_back['net_interfaces'][1]['routes']).to eq('v4' => ['198.51.100.1/32'])
    end
  end
end
# rubocop:enable RSpec/DescribeClass
