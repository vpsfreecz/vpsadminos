# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/netif_stats'

RSpec.describe OsCtl::Lib::NetifStats do
  def with_fake_net_sysfs
    with_tmpdir do |dir|
      net_root = File.join(dir, 'sys/class/net')
      %w[lo bond0 face eth2.100 eth0 eth1 br0].each do |netif|
        FileUtils.mkdir_p(File.join(net_root, netif, 'statistics'))
      end

      write_sysfs_file(net_root, 'eth0/statistics/tx_bytes', "10\n")
      write_sysfs_file(net_root, 'eth0/statistics/tx_packets', "11\n")
      write_sysfs_file(net_root, 'eth0/statistics/rx_bytes', "12\n")
      write_sysfs_file(net_root, 'eth0/statistics/rx_packets', "13\n")
      write_sysfs_file(net_root, 'eth1/statistics/tx_bytes', "20\n")
      write_sysfs_file(net_root, 'eth1/statistics/tx_packets', "21\n")
      write_sysfs_file(net_root, 'eth1/statistics/rx_bytes', "22\n")
      write_sysfs_file(net_root, 'eth1/statistics/rx_packets', "23\n")

      allow(Dir).to receive(:entries).with('/sys/class/net').and_return(Dir.entries(net_root))
      allow(File).to receive(:read).and_wrap_original do |method, path, *args|
        if path.start_with?('/sys/class/net')
          method.call(path.sub('/sys/class/net', net_root), *args)
        else
          method.call(path, *args)
        end
      end

      yield(net_root)
    end
  end

  it 'lists eligible interfaces and reads/caches their statistics' do
    with_fake_net_sysfs do |net_root|
      stats = described_class.new

      expect(stats.list_netifs.sort).to eq(%w[br0 eth0 eth1])

      expect(stats.get_stats_for('eth0')).to eq(
        tx: { bytes: 10, packets: 11 },
        rx: { bytes: 12, packets: 13 }
      )

      write_sysfs_file(net_root, 'eth0/statistics/tx_bytes', "100\n")

      expect(stats.get_stats_for('eth0')[:tx][:bytes]).to eq(10)

      stats.reset

      expect(stats.get_stats_for('eth0')[:tx][:bytes]).to eq(100)
      expect(stats.get_stats_for('br0')).to eq(
        tx: { bytes: 0, packets: 0 },
        rx: { bytes: 0, packets: 0 }
      )
    end
  end

  it 'returns stats for all interfaces and caches selected interfaces eagerly' do
    with_fake_net_sysfs do
      stats = described_class.new

      stats.cache_stats_for_interfaces(%w[eth0 eth1])

      expect(stats['eth0'][:tx][:bytes]).to eq(10)
      expect(stats['eth1'][:rx][:packets]).to eq(23)
      expect(stats.get_stats_for_all.keys.sort).to eq(%w[br0 eth0 eth1])
    end
  end
end
