# frozen_string_literal: true

require 'osctld/container/impermanence'

RSpec.describe OsCtld::Container::Impermanence do
  it 'loads zfs properties from config' do
    impermanence = described_class.load(
      'zfs_properties' => {
        'com.example:keep' => '1'
      }
    )

    expect(impermanence.zfs_properties).to eq('com.example:keep' => '1')
  end

  it 'dumps the current zfs properties' do
    impermanence = described_class.new('com.example:keep' => '1')

    expect(impermanence.dump).to eq(
      'zfs_properties' => {
        'com.example:keep' => '1'
      }
    )
  end

  it 'deep-copies the property hash on dup' do
    impermanence = described_class.new('com.example:keep' => '1')

    copy = impermanence.dup
    copy.zfs_properties['com.example:keep'] = '2'

    expect(impermanence.zfs_properties).to eq('com.example:keep' => '1')
    expect(copy.zfs_properties).to eq('com.example:keep' => '2')
  end
end
