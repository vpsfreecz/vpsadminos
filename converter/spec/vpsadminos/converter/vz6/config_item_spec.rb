# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/devices'
require 'vpsadminos-converter/vz6/config_item'

RSpec.describe VpsAdminOS::Converter::Vz6::ConfigItem do
  def value_for(key, value, ctid: '101')
    described_class.new(ctid, key, value).value
  end

  it 'passes through plain string values for supported keys' do
    expect(value_for('NAME', 'demo')).to eq('demo')
    expect(value_for('HOSTNAME', 'demo.example')).to eq('demo.example')
  end

  it 'substitutes VEID in VE_ROOT and VE_PRIVATE' do
    expect(value_for('VE_ROOT', '/vz/root/$VEID')).to eq('/vz/root/101')
    expect(value_for('VE_PRIVATE', '/vz/private/${VEID}')).to eq('/vz/private/101')
  end

  it 'parses booleans and rejects invalid values' do
    expect(value_for('ONBOOT', 'yes')).to be(true)
    expect(value_for('DISABLED', 'no')).to be(false)
    expect { value_for('ONBOOT', 'maybe') }.to raise_error(
      RuntimeError,
      'unexpected boolean value ONBOOT="maybe"'
    )
  end

  it 'parses numeric values' do
    expect(value_for('BOOTORDER', '50')).to eq(50)
    expect(value_for('CPUS', '8')).to eq(8)
  end

  it 'parses address lists into IPAddress objects' do
    values = value_for('NAMESERVER', '192.0.2.1 2001:db8::1')

    expect(values.map(&:to_s)).to eq(['192.0.2.1', '2001:db8::1'])
  end

  it 'parses whitespace-separated lists' do
    expect(value_for('SEARCHDOMAIN', 'example.test example.org')).to eq(
      %w[example.test example.org]
    )
  end

  it 'parses memory limits with duplicated single values and explicit pairs' do
    expect(value_for('PHYSPAGES', '1024')).to eq([1024, 1024])
    expect(value_for('SWAPPAGES', '1024:2048')).to eq([1024, 2048])
  end

  it 'parses limit suffixes, pages, unlimited, and rejects invalid suffixes' do
    item = described_class.new('101', 'PHYSPAGES', '1')

    expect(item.send(:parse_unit, '1B')).to eq(1)
    expect(item.send(:parse_unit, '1K')).to eq(1024)
    expect(item.send(:parse_unit, '1M')).to eq(1024**2)
    expect(item.send(:parse_unit, '1G')).to eq(1024**3)
    expect(item.send(:parse_unit, '1T')).to eq(1024**4)
    expect(item.send(:parse_unit, '10P')).to eq(10)
    expect(item.send(:parse_unit, 'unlimited')).to eq(0)
    expect(item.send(:parse_unit, '1G', pages: true)).to eq((1024**3) / 4096)
    expect { item.send(:parse_unit, '10X') }.to raise_error(
      RuntimeError,
      "unsupported suffix 'X'"
    )
  end

  it 'parses device lists' do
    devices = value_for('DEVICES', 'b:8:0:rwq c:1:3:none')

    expect(devices.map(&:to_s)).to eq(['b:8:0:rwq', 'c:1:3:none'])
  end

  it 'parses on/off lists' do
    expect(value_for('FEATURES', 'nfs:on fuse:off')).to eq(
      'nfs' => true,
      'fuse' => false
    )
  end

  describe VpsAdminOS::Converter::Vz6::ConfigItem::Device do
    it 'converts block and char devices to container devices' do
      block = described_class.new('b', '8', '0', 'rwq').to_ct_device
      char = described_class.new('c', '1', '3', 'none').to_ct_device

      expect(block.dump).to eq(
        'type' => 'block',
        'major' => '8',
        'minor' => '0',
        'mode' => 'rw',
        'name' => nil,
        'inherit' => true
      )
      expect(char.dump).to eq(
        'type' => 'char',
        'major' => '1',
        'minor' => '3',
        'mode' => '',
        'name' => nil,
        'inherit' => true
      )
    end

    it 'rejects unsupported device types' do
      expect do
        described_class.new('x', '1', '3', 'rwm').to_ct_device
      end.to raise_error(RuntimeError, "unsupported device type 'x'")
    end
  end
end
