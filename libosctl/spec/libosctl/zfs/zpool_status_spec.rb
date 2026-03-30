# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/zfs/zpool_status'

RSpec.describe OsCtl::Lib::Zfs::ZpoolStatus do
  it 'parses pool states, scan progress, roles, and nested vdevs' do
    status = described_class.new(status_string: <<~STATUS)
      pool: tank
      state: ONLINE
      scan: scrub in progress since Mon Mar 30 00:00:00 2026
            10G scanned at 1G/s, 5G issued at 500M/s, 20G total, 50.00% done, 00:01:00 to go
      config:

      \tNAME STATE READ WRITE CKSUM
      \ttank ONLINE 0 0 0
      \t  mirror-0 ONLINE 0 0 0
      \t    /dev/disk1 ONLINE 0 0 0
      \t    /dev/disk2 ONLINE 0 0 0
      \tlogs
      \t  /dev/log0 ONLINE 0 0 0
      \tcache
      \t  /dev/cache0 ONLINE 0 0 0

      pool: fast
      state: DEGRADED
      scan: resilver in progress since Mon Mar 30 00:00:00 2026
            10G scanned at 1G/s, 5G issued at 500M/s, 20G total, 25.50% done, 00:01:00 to go
      config:

      \tNAME STATE READ WRITE CKSUM
      \tfast DEGRADED 0 0 0
      \t  raidz1-0 DEGRADED 0 0 0
      \t    /dev/disk3 ONLINE 0 0 0
      \t    /dev/disk4 FAULTED 1 2 3
    STATUS

    expect(status.pools.map(&:name)).to eq(%w[tank fast])

    tank = status['tank']
    expect(tank.state).to eq(:online)
    expect(tank.scan).to eq(:scrub)
    expect(tank.scan_percent).to eq(50.0)
    expect(tank.virtual_devices.first).to have_attributes(
      role: :storage,
      name: 'mirror-0',
      type: 'mirror',
      state: :online
    )
    expect(tank.virtual_devices.first.virtual_devices.map(&:name)).to eq(['/dev/disk1', '/dev/disk2'])
    expect(tank.virtual_devices[1]).to have_attributes(role: :log, name: '/dev/log0', type: 'disk')
    expect(tank.virtual_devices[2]).to have_attributes(role: :cache, name: '/dev/cache0', type: 'disk')

    fast = status['fast']
    expect(fast.state).to eq(:degraded)
    expect(fast.scan).to eq(:resilver)
    expect(fast.scan_percent).to eq(25.5)
    expect(fast.virtual_devices.first.virtual_devices.last).to have_attributes(
      name: '/dev/disk4',
      state: :faulted,
      read: 1,
      write: 2,
      checksum: 3
    )
  end
end
