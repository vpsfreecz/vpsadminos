# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/cpu_mask'

RSpec.describe OsCtl::Lib::CpuMask do
  it 'parses lists and ranges and exposes enumerable helpers' do
    mask = described_class.new('0,2-4')

    expect(mask).to include(3)
    expect(mask).not_to include(1)
    expect(mask.size).to eq(4)
    expect(mask.each.to_a).to eq([0, 2, 3, 4])
    expect(mask.to_a).to eq([0, 2, 3, 4])
    expect(mask.to_s).to eq('0,2-4')
  end

  it 'expands the wildcard mask using the processor count' do
    allow(Etc).to receive(:nprocessors).and_return(4)

    mask = described_class.new('*')

    expect(mask.to_a).to eq([0, 1, 2, 3])
    expect(mask.to_s).to eq('0-3')
  end

  it 'formats non-contiguous masks and intersects masks' do
    expect(described_class.format([0, 1, 3, 5, 6])).to eq('0,1,3,5,6')

    left = described_class.new([0, 1, 3, 5, 6])
    right = described_class.new('1-3,6')

    expect((left & right).to_a).to eq([1, 3, 6])
  end
end
