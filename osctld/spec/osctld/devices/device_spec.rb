# frozen_string_literal: true

require 'osctld/devices/device'
require 'osctld/devices/mode'

RSpec.describe OsCtld::Devices::Device do
  it 'loads and imports devices with normalized fields' do
    loaded = described_class.load(
      'type' => 'char',
      'major' => '1',
      'minor' => 'all',
      'mode' => 'wr',
      'name' => '/dev/null',
      'inherit' => true
    )
    imported = described_class.import(
      type: 'block',
      major: 8,
      minor: 0,
      mode: 'mr',
      dev_name: '/dev/sda',
      inherit: false
    )

    expect(loaded.to_s).to eq('c 1:* rw')
    expect(imported.to_s).to eq('b 8:0 rm')
    expect(imported.type_s).to eq('b')
  end

  it 'tracks chmod diffs and exports state' do
    device = described_class.new(:char, 1, 3, 'rm', name: '/dev/null')

    expect(device.chmod(OsCtld::Devices::Mode.new('wm'))).to eq(
      allow: 'c 1:3 w',
      deny: 'c 1:3 r'
    )
    expect(device.dump).to include(
      'type' => 'char',
      'major' => 1,
      'minor' => 3,
      'mode' => 'wm',
      'name' => '/dev/null'
    )
  end

  it 'tracks inheritance flags and compares by type major minor only' do
    promoted = described_class.new(:char, 1, 3, 'r', inherit: false, inherited: false)
    inherited = described_class.new(:char, 1, 3, 'w', inherit: true, inherited: true)

    expect(promoted.promoted?).to be(true)
    expect(inherited.inherit?).to be(true)
    expect(inherited.inherited?).to be(true)
    expect(promoted).to eq(inherited)
  end
end
