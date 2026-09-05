# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::PortReservation do
  before do
    described_class.reset_to_ports([10_000, 10_001, 10_002, 10_003])
  end

  it 'returns a stable port per key' do
    first = described_class.get_port(key: 'alpha')
    second = described_class.get_port(key: 'alpha')

    expect(first).to eq(second)
  end

  it 'gives different keys different ports' do
    expect(described_class.get_port(key: 'alpha')).not_to eq(described_class.get_port(key: 'beta'))
  end

  it 'reserves arrays of ports' do
    expect(described_class.get_ports(key: 'alpha', size: 2)).to eq([10_000, 10_001])
  end

  it 'returns released ports to the pool' do
    port = described_class.get_port(key: 'alpha')

    described_class.release_port(key: 'alpha')

    expect(described_class.instance.instance_variable_get(:@ports)).to include(port)
  end

  it 'returns released port arrays to the pool' do
    ports = described_class.get_ports(key: 'alpha', size: 2)

    described_class.release_ports(key: 'alpha')

    expect(described_class.instance.instance_variable_get(:@ports)).to include(*ports)
  end

  it 'resets allocator scope to the given ports' do
    described_class.get_port(key: 'alpha')

    described_class.reset_to_ports([20_000, 20_001])

    expect(described_class.get_port(key: 'beta')).to eq(20_000)
  end

  it 'isolates allocations made by independent processes' do
    Dir.mktmpdir do |dir|
      first = described_class.send(:new)
      second = described_class.send(:new)

      [first, second].each do |allocator|
        allocator.instance_variable_set(:@ports, [10_000, 10_001])
        allow(allocator).to receive(:lock_directory).and_return(dir)
      end

      expect(first.get_port(key: 'first')).to eq(10_000)
      expect(second.get_port(key: 'second')).to eq(10_001)
    ensure
      first&.release_port(key: 'first')
      second&.release_port(key: 'second')
    end
  end

  it 'uses a host-wide lock directory for the current user' do
    allocator = described_class.send(:new)

    expect(allocator.send(:lock_directory)).to eq("/var/tmp/osvm-port-reservations-#{Process.uid}")
  end

  it 'supports a configured host-wide lock root' do
    allocator = described_class.send(:new)
    original_root = ENV.fetch('OSVM_PORT_RESERVATION_ROOT', nil)

    Dir.mktmpdir do |dir|
      ENV['OSVM_PORT_RESERVATION_ROOT'] = dir

      expect(allocator.send(:lock_directory)).to eq(File.join(dir, "osvm-port-reservations-#{Process.uid}"))
    end
  ensure
    if original_root.nil?
      ENV.delete('OSVM_PORT_RESERVATION_ROOT')
    else
      ENV['OSVM_PORT_RESERVATION_ROOT'] = original_root
    end
  end
end
