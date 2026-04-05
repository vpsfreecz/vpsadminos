# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/devices'

RSpec.describe VpsAdminOS::Converter::Devices do
  describe VpsAdminOS::Converter::Devices::Device do
    it 'defaults inherit to true' do
      device = described_class.new('char', '1', '3', 'rwm')

      expect(device.inherit).to be(true)
    end

    it 'accepts inherit false' do
      device = described_class.new('char', '1', '3', 'rwm', inherit: false)

      expect(device.inherit).to be(false)
    end

    it 'dumps the device config' do
      device = described_class.new('block', '8', '0', 'rw', name: 'sda', inherit: false)

      expect(device.dump).to eq(
        'type' => 'block',
        'major' => '8',
        'minor' => '0',
        'mode' => 'rw',
        'name' => 'sda',
        'inherit' => false
      )
    end
  end

  it 'dumps all devices in order' do
    devices = described_class.new
    devices << described_class::Device.new('char', '1', '3', 'rwm')
    devices << described_class::Device.new('block', '8', '0', 'rw', name: 'sda')

    expect(devices.dump).to eq(
      [
        {
          'type' => 'char',
          'major' => '1',
          'minor' => '3',
          'mode' => 'rwm',
          'name' => nil,
          'inherit' => true
        },
        {
          'type' => 'block',
          'major' => '8',
          'minor' => '0',
          'mode' => 'rw',
          'name' => 'sda',
          'inherit' => true
        }
      ]
    )
  end
end
