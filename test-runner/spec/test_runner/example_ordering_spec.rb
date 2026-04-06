# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::ExampleOrdering do
  let(:items) { [1, 2, 3] }

  it 'preserves defined ordering' do
    expect(described_class.sort_by_order(items, :defined)).to eq(items)
  end

  it 'supports random ordering' do
    expect(described_class.sort_by_order(items, :rand)).to match_array(items)
  end

  it 'supports explicit Random instances' do
    first = described_class.sort_by_order(items, Random.new(1))
    second = described_class.sort_by_order(items, Random.new(1))

    expect(first).to eq(second)
  end

  it 'supports integer seeds' do
    first = described_class.sort_by_order(items, 1)
    second = described_class.sort_by_order(items, 1)

    expect(first).to eq(second)
  end

  it 'raises on invalid order values' do
    expect do
      described_class.sort_by_order(items, :bogus)
    end.to raise_error(RuntimeError, /Invalid order/)
  end
end
