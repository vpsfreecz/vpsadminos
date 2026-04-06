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
end
