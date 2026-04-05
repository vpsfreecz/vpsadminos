# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::IpAllocator do
  subject(:allocator) { described_class.new('10.100.10.0/30') }

  it 'allocates unique IP addresses in order' do
    expect([allocator.get.to_s, allocator.get.to_s]).to eq(%w[10.100.10.1 10.100.10.2])
  end

  it 'returns an address to the pool' do
    first = allocator.get
    allocator.get

    allocator.put(first)

    expect(allocator.get.to_s).to eq(first.to_s)
  end

  it 'raises on attempts to return an IP that was not allocated' do
    ip = IPAddress.parse('10.100.10.10')

    expect { allocator.put(ip) }.to raise_error(ArgumentError, '10.100.10.10 was not allocated')
  end

  it 'raises a deterministic error when the pool is exhausted' do
    allocator.get
    allocator.get

    expect { allocator.get }.to raise_error(OsCtl::Image::OperationError, 'no IP addresses available')
  end
end
